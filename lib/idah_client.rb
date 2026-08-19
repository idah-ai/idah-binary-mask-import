# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "openssl"
require "securerandom"
require "rack/mime"

# Handles all API communication with IDAH services.
#
# Authentication flow:
#   1. Exchange the API key for a JWT via POST /auth/api/login
#   2. Use the JWT as a Bearer token for all subsequent API calls
class IdahClient
  def initialize(api_url:, api_key:, insecure: false)
    @api_url = api_url
    @api_key = api_key
    @insecure = insecure
    @token = nil
  end

  # ── Authentication ───────────────────────────────────────────────────

  # Exchange the API key for a JWT token.
  # Must be called before any other API operations.
  def authenticate!(token_expiration: 3600)
    payload = { api_key: @api_key, token_expiration: token_expiration }

    uri = URI("#{@api_url}/api/v1/iam/auth/api/login")
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(payload)

    response = Net::HTTP.start(uri.hostname, uri.port, **http_options) do |http|
      http.request(request)
    end

    body = JSON.parse(response.body)
    unless response.code.to_i >= 200 && response.code.to_i < 300
      raise "Authentication failed (#{response.code}): #{body}"
    end

    @token = body.dig("meta", "token")
    raise "Authentication failed: no token in response" unless @token

    @token
  end

  # ── Dataset ──────────────────────────────────────────────────────────

  def create_dataset(project_id, name, labeling_configuration: nil)
    attributes = {
      name: name,
      modality: "idah-image",
      workflow_configuration: {},
    }
    attributes[:labeling_configuration] = labeling_configuration if labeling_configuration

    payload = {
      data: {
        type: "dataset:datasets",
        attributes: attributes,
        relationships: {
          project: { data: { type: "dataset:projects", id: project_id } }
        }
      }
    }
    post("/api/v1/dataset/datasets", payload)
  end

  # ── Media Upload (must happen before entry creation) ─────────────────

  # Upload a media file and return the uploaded media records.
  # Each record has a `resource` field used to create the entry.
  def upload_media(file_path, project_id, resource:, modality: "idah-image", key: "")
    uri = URI("#{@api_url}/api/v1/media/medias/files/#{resource}")
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{@token}"

    mime_type = Rack::Mime.mime_type(File.extname(file_path), "application/octet-stream")
    form_data = [
      ["file", File.open(file_path, "rb"), { content_type: mime_type }],
      ["project_id", project_id],
      ["resource", resource],
      ["key", key],
      ["modality", modality]
    ]
    request.set_form(form_data, "multipart/form-data")

    response = Net::HTTP.start(uri.hostname, uri.port, **http_options) do |http|
      http.request(request)
    end

    raise "Upload failed: #{response.code} #{response.body}" unless response.code.to_i == 200

    JSON.parse(response.body)
  end

  # ── Entry (created after media upload, using the media's resource) ───

  def create_entry(dataset_id, name:, resource:)
    payload = {
      data: {
        type: "dataset:entries",
        attributes: { name: name, resource: resource },
        relationships: {
          dataset: { data: { type: "dataset:datasets", id: dataset_id } }
        }
      }
    }
    post("/api/v1/dataset/entries", payload)
  end

  # ── Annotation (JSON-RPC) ────────────────────────────────────────────

  def create_annotation(entry_id, shape_type:, shape_args: {}, category:, properties: {}, metadata: {}, id: nil)
    id ||= SecureRandom.uuid
    params = {
      id: id,
      entry_id: entry_id,
      shape_type: shape_type,
      shape_args: shape_args,
      category: category,
      properties: properties,
      metadata: metadata
    }
    json_rpc("create", params)
  end

  def write_shape(annotation_id, key, value)
    params = {
      annotation_id: annotation_id,
      key: key,
      value: value
    }
    json_rpc("write_shape", params)
  end

  private

  def http_options
    opts = { use_ssl: URI(@api_url).scheme == "https" }
    opts[:verify_mode] = OpenSSL::SSL::VERIFY_NONE if @insecure
    opts
  end

  def bearer_token
    @token or raise "Not authenticated. Call authenticate! first."
  end

  def post(path, payload)
    uri = URI("#{@api_url}#{path}")
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/vnd.api+json"
    request["Authorization"] = "Bearer #{bearer_token}"
    request.body = JSON.generate(payload)

    response = Net::HTTP.start(uri.hostname, uri.port, **http_options) do |http|
      http.request(request)
    end

    body = JSON.parse(response.body)
    unless response.code.to_i >= 200 && response.code.to_i < 300
      raise "API error #{response.code}: #{body}"
    end

    body
  end

  def json_rpc(method, params)
    payload = {
      jsonrpc: "2.0",
      method: method,
      params: params,
      id: 1
    }

    uri = URI("#{@api_url}/api/v1/dataset/annotations/_rpc")
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Bearer #{bearer_token}"
    request.body = JSON.generate(payload)

    response = Net::HTTP.start(uri.hostname, uri.port, **http_options) do |http|
      http.request(request)
    end

    body = JSON.parse(response.body)
    if body["error"]
      raise "RPC error: #{body["error"]}"
    end

    body["result"]
  end
end
