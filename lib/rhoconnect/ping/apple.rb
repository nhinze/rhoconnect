require 'json'
require 'openssl'
require 'jwt'
require 'net-http2'

# https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns
#
# This used to speak the legacy binary protocol over a raw TLS socket to
# gateway.push.apple.com:2195, authenticated with a push certificate. Apple
# retired that service in 2021 and the hostname no longer resolves at all, so
# every iOS ping failed with "getaddrinfo: Name or service not known". The
# provider API is HTTP/2 with a signed JWT, which is what this does now.
module Rhoconnect
  class Apple
    class ApnsError < Exception; end

    PRODUCTION_HOST = 'https://api.push.apple.com'
    SANDBOX_HOST    = 'https://api.sandbox.push.apple.com'

    # APNs reports these against the device rather than the request: the app was
    # deleted, the token was restored onto another device, or it belongs to the
    # other APNs environment. The ping is not at fault and a retry cannot help,
    # so they are logged and skipped rather than raised -- otherwise a single
    # dead device puts every ping job in the failed queue for good.
    DEAD_DEVICE_REASONS = %w(BadDeviceToken Unregistered DeviceTokenNotForTopic).freeze

    def self.ping(params)
      settings = get_config(Rhoconnect.base_directory)[Rhoconnect.environment] || {}

      key     = auth_key(settings)
      key_id  = setting(settings, :apns_key_id,  'APNS_KEY_ID')
      team_id = setting(settings, :apns_team_id, 'APNS_TEAM_ID')
      topic   = setting(settings, :apns_topic,   'APNS_TOPIC')

      if key.nil? or key_id.nil? or team_id.nil? or topic.nil?
        log 'Invalid APNs settings: ping is ignored.'
        log "auth_key: #{key ? 'present' : 'missing'}, apns_key_id: #{key_id.inspect}, " \
            "apns_team_id: #{team_id.inspect}, apns_topic: #{topic.inspect}"
        return
      end

      device_token = params['device_pin'].to_s.delete(' ')
      if device_token.empty?
        log 'Skipping APNs ping: client has no device_pin.'
        return
      end

      host = settings[:apns_host] || PRODUCTION_HOST
      token = provider_token(key, key_id, team_id)

      status, body = post_notification(
        host, device_token, push_headers(params, token, topic), apn_message(params)
      )
      return if status == 200

      reason = failure_reason(body)
      if DEAD_DEVICE_REASONS.include?(reason)
        log "APNs rejected the device token as no longer valid (#{reason}); skipping this device."
        return
      end

      error = ApnsError.new("APNs ping failed: #{status} #{reason}")
      log error
      raise error
    end

    # Apple rejects a provider token older than an hour and asks that one be
    # reused rather than minted per request. Resque runs every job in a forked
    # child that then exits, so there is no process here to cache one in; at
    # ping volumes this stays well inside the rate Apple tolerates.
    def self.provider_token(key, key_id, team_id)
      JWT.encode(
        { 'iss' => team_id, 'iat' => Time.now.to_i },
        OpenSSL::PKey.read(key),
        'ES256',
        { 'kid' => key_id }
      )
    end

    def self.push_headers(params, provider_token, topic)
      alert = !params['message'].to_s.empty?
      {
        'authorization' => "bearer #{provider_token}",
        'apns-topic'    => topic,
        # APNs requires priority 5 for a background push and rejects 10.
        'apns-push-type' => alert ? 'alert' : 'background',
        'apns-priority'  => alert ? '10' : '5'
      }
    end

    # Generates the APNs payload
    def self.apn_message(params)
      aps = {}
      aps['alert']   = params['message'] if params['message']
      aps['badge']   = params['badge'].to_i if params['badge']
      aps['sound']   = params['sound'] if params['sound']
      aps['vibrate'] = params['vibrate'] if params['vibrate']
      # Wakes the app so it can run the sync the ping exists to ask for. Without
      # it a data-only push reaches the device but is never handed over.
      aps['content-available'] = 1

      message = { 'aps' => aps }
      # A comma separated list, as Fcm sends and as the device expects:
      # SyncController#push_callback calls split(',') on it. The binary
      # implementation sent the raw Array, which the client could not split.
      message['do_sync'] = Array(params['sources']).join(',') if params['sources']
      message
    end

    def self.post_notification(host, device_token, headers, payload)
      client = NetHttp2::Client.new(host)
      begin
        response = client.call(:post, "/3/device/#{device_token}",
                               :body => JSON.dump(payload),
                               :headers => headers,
                               :timeout => 30)
        raise ApnsError.new('No response from APNs') if response.nil?
        [response.status.to_i, response.body.to_s]
      ensure
        client.close
      end
    end

    # The key is read from the environment first so it need not be committed;
    # settings[:apns_auth_key] is a path relative to the app, as the retired
    # :iphonecertfile was.
    def self.auth_key(settings)
      from_env = ENV['APNS_AUTH_KEY'].to_s
      return from_env unless from_env.empty?

      path = settings[:apns_auth_key].to_s
      return nil if path.empty?

      path = File.join(Rhoconnect.base_directory, path)
      File.exist?(path) ? File.read(path) : nil
    end

    def self.setting(settings, key, env_var)
      value = settings[key]
      value = ENV[env_var] if value.to_s.empty?
      value.to_s.empty? ? nil : value
    end

    def self.failure_reason(body)
      parsed = JSON.parse(body.to_s)
      parsed.is_a?(Hash) ? (parsed['reason'] || body.to_s) : body.to_s
    rescue JSON::ParserError
      body.to_s
    end
  end

  # Deprecated - use Apple instead
  class Iphone < Apple
    def self.ping(params)
      log "DEPRECATION WARNING: 'iphone' is a deprecated device_type, use 'apple' instead"
      super(params)
    end
  end
end
