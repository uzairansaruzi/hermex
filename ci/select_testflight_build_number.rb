#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "time"
require "uri"

class TestFlightBuildNumberSelector
  API_BASE = "https://api.appstoreconnect.apple.com"
  BUILD_NUMBER_PATTERN = /\A\d+(?:\.\d+)*\z/

  # App Store version states in which Apple has approved the version and closed
  # its pre-release train: any later upload must carry a higher
  # CFBundleShortVersionString (ASC upload errors 90186/90062, hit on
  # 2026-06-02 with 1.0 and again on 2026-08-04 with 1.4).
  APPROVED_APP_STORE_STATES = %w[
    READY_FOR_SALE
    READY_FOR_DISTRIBUTION
    PENDING_DEVELOPER_RELEASE
    PENDING_APPLE_RELEASE
    PROCESSING_FOR_APP_STORE
  ].freeze

  class SelectionError < StandardError; end

  def self.valid_build_number?(value)
    BUILD_NUMBER_PATTERN.match?(value.to_s)
  end

  def self.compare_build_numbers(left, right)
    validate_build_number!(left, "left build number")
    validate_build_number!(right, "right build number")

    left_parts = left.split(".").map(&:to_i)
    right_parts = right.split(".").map(&:to_i)
    max_length = [left_parts.length, right_parts.length].max

    max_length.times do |index|
      left_value = left_parts[index] || 0
      right_value = right_parts[index] || 0
      return -1 if left_value < right_value
      return 1 if left_value > right_value
    end

    0
  end

  def self.increment_build_number(value)
    validate_build_number!(value, "latest build number")

    parts = value.split(".").map(&:to_i)
    parts[-1] += 1
    parts.join(".")
  end

  def self.select_build_number(requested_build_number:, latest_build_number:)
    requested = requested_build_number.to_s.strip

    unless requested.empty?
      validate_build_number!(requested, "requested build number")

      if latest_build_number && compare_build_numbers(requested, latest_build_number) <= 0
        raise SelectionError,
              "Requested build number #{requested} must be greater than latest App Store Connect build #{latest_build_number}."
      end

      return requested
    end

    latest_build_number ? increment_build_number(latest_build_number) : "1"
  end

  # Returns the approved App Store version that closes the train for
  # marketing_version, or nil when the train is open. Approved version strings
  # that are not plain dotted numerics cannot be compared and are ignored.
  def self.closed_train_version(marketing_version:, approved_versions:)
    validate_build_number!(marketing_version, "marketing version")

    approved_versions
      .select { |value| valid_build_number?(value) }
      .find { |value| compare_build_numbers(marketing_version, value) <= 0 }
  end

  def self.validate_build_number!(value, label)
    return if valid_build_number?(value)

    raise SelectionError, "#{label.capitalize} must contain only digits and dots. Received: #{value}"
  end

  def initialize(env: ENV, now: Time.now)
    @env = env
    @now = now
    @jwt_token = nil
  end

  def run
    bundle_id = required_env("BUNDLE_ID")
    marketing_version = required_env("MARKETING_VERSION")
    requested_build_number = @env.fetch("REQUESTED_BUILD_NUMBER", "")

    enforce_open_train!(bundle_id: bundle_id, marketing_version: marketing_version) if @env["ENFORCE_OPEN_TRAIN"] == "1"

    latest = latest_uploaded_build_number(bundle_id: bundle_id, marketing_version: marketing_version)
    selected = self.class.select_build_number(
      requested_build_number: requested_build_number,
      latest_build_number: latest
    )

    if requested_build_number.to_s.strip.empty?
      warn "Latest App Store Connect build for #{bundle_id} #{marketing_version}: #{latest || "none"}"
      warn "Selected next build number: #{selected}"
    else
      warn "Latest App Store Connect build for #{bundle_id} #{marketing_version}: #{latest || "none"}"
      warn "Using requested build number: #{selected}"
    end

    selected
  end

  private

  # Fails fast — before the ~15-minute archive step — when App Store Connect
  # would reject the upload anyway because marketing_version's pre-release
  # train is closed by an approved App Store version.
  def enforce_open_train!(bundle_id:, marketing_version:)
    blocking = self.class.closed_train_version(
      marketing_version: marketing_version,
      approved_versions: approved_app_store_versions(bundle_id: bundle_id)
    )

    if blocking
      raise SelectionError,
            "The #{marketing_version} pre-release train is closed: App Store version #{blocking} is already approved. " \
            "Bump MARKETING_VERSION in HermesMobile.xcodeproj/project.pbxproj above #{blocking}, land it on master, " \
            "and re-run this workflow (see TESTFLIGHT.md, Upload External-Capable Build)."
    end

    warn "Pre-release train #{marketing_version} is open: no approved App Store version at or above it."
  end

  def approved_app_store_versions(bundle_id:)
    app_id = app_id_for_bundle_id(bundle_id)
    versions = fetch_paginated_json(
      "/v1/apps/#{app_id}/appStoreVersions",
      "fields[appStoreVersions]" => "versionString,appStoreState",
      "limit" => "200"
    )

    versions
      .select { |item| APPROVED_APP_STORE_STATES.include?(item.dig("attributes", "appStoreState")) }
      .map { |item| item.dig("attributes", "versionString") }
      .compact
  end

  def latest_uploaded_build_number(bundle_id:, marketing_version:)
    app_id = app_id_for_bundle_id(bundle_id)
    builds = fetch_paginated_json(
      "/v1/builds",
      "filter[app]" => app_id,
      "filter[preReleaseVersion.version]" => marketing_version,
      "fields[builds]" => "version,uploadedDate",
      "limit" => "200"
    )

    build_numbers = builds.map { |item| item.dig("attributes", "version") }.compact
    invalid_build_numbers = build_numbers.reject { |value| self.class.valid_build_number?(value) }
    unless invalid_build_numbers.empty?
      raise SelectionError,
            "Cannot auto-select after non-numeric App Store Connect build numbers: #{invalid_build_numbers.uniq.join(", ")}"
    end

    build_numbers.max { |left, right| self.class.compare_build_numbers(left, right) }
  end

  # Memoized: the train preflight and build-number selection both need it.
  def app_id_for_bundle_id(bundle_id)
    @app_ids ||= {}
    cached = @app_ids[bundle_id]
    return cached if cached

    @app_ids[bundle_id] = uncached_app_id_for_bundle_id(bundle_id)
  end

  def uncached_app_id_for_bundle_id(bundle_id)
    apps = fetch_paginated_json(
      "/v1/apps",
      "filter[bundleId]" => bundle_id,
      "fields[apps]" => "bundleId,name,sku",
      "limit" => "10"
    )

    app = apps.find { |item| item.dig("attributes", "bundleId") == bundle_id }
    raise SelectionError, "No App Store Connect app found for bundle ID #{bundle_id}." unless app

    app.fetch("id")
  end

  def fetch_paginated_json(path, params)
    url = URI.join(API_BASE, path)
    url.query = URI.encode_www_form(params)
    items = []

    loop do
      response = fetch_json(url)
      data = response.fetch("data")
      raise SelectionError, "Expected App Store Connect data array from #{url}." unless data.is_a?(Array)

      items.concat(data)
      next_url = response.dig("links", "next")
      break if next_url.to_s.empty?

      url = URI(next_url)
    end

    items
  end

  def fetch_json(url)
    request = Net::HTTP::Get.new(url)
    request["Authorization"] = "Bearer #{jwt_token}"
    request["Accept"] = "application/json"

    response = Net::HTTP.start(
      url.hostname,
      url.port,
      use_ssl: url.scheme == "https",
      open_timeout: 10,
      read_timeout: 30
    ) do |http|
      http.request(request)
    end

    unless response.is_a?(Net::HTTPSuccess)
      raise SelectionError, "App Store Connect request failed with HTTP #{response.code}: #{response.body}"
    end

    JSON.parse(response.body)
  rescue JSON::ParserError => error
    raise SelectionError, "App Store Connect returned invalid JSON: #{error.message}"
  end

  def jwt_token
    @jwt_token ||= begin
      issued_at = @now.to_i - 60
      header = {
        alg: "ES256",
        kid: required_env("APP_STORE_CONNECT_KEY_ID"),
        typ: "JWT"
      }
      payload = {
        iss: required_env("APP_STORE_CONNECT_ISSUER_ID"),
        iat: issued_at,
        exp: issued_at + (20 * 60),
        aud: "appstoreconnect-v1"
      }

      signing_input = [base64url(header.to_json), base64url(payload.to_json)].join(".")
      signature = base64url(es256_signature(signing_input))
      "#{signing_input}.#{signature}"
    end
  end

  def es256_signature(signing_input)
    key = OpenSSL::PKey.read(File.read(required_env("APP_STORE_CONNECT_KEY_PATH")))
    der_signature = key.sign(OpenSSL::Digest::SHA256.new, signing_input)
    sequence = OpenSSL::ASN1.decode(der_signature)

    r = sequence.value[0].value.to_i
    s = sequence.value[1].value.to_i
    hex_signature = [r.to_s(16).rjust(64, "0"), s.to_s(16).rjust(64, "0")].join
    [hex_signature].pack("H*")
  end

  def base64url(value)
    Base64.strict_encode64(value).tr("+/", "-_").delete("=")
  end

  def required_env(name)
    value = @env[name].to_s
    raise SelectionError, "Missing required environment variable: #{name}" if value.empty?

    value
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    puts TestFlightBuildNumberSelector.new.run
  rescue TestFlightBuildNumberSelector::SelectionError => error
    warn error.message
    exit 1
  end
end
