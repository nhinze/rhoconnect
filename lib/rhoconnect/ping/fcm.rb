require 'google/apis/messages'

# https://firebase.google.com/docs/cloud-messaging/auth-server
# https://github.com/oniksfly/google-api-fcm

module Rhoconnect
  class Fcm
    class InvalidProjectId < Exception; end
    class InvalidPackageName < Exception; end
    class FCMPingError < Exception; end

    def self.ping(params)
      begin
        fcm_project_id = Rhoconnect.settings[:fcm_project_id]
        raise InvalidProjectId.new("Missing `:fcm_project_id:` option in settings/settings.yml") unless fcm_project_id

        package_name = Rhoconnect.settings[:package_name]
        raise InvalidPackageName.new("Missing `:package_name:` option in settings/settings.yml") unless package_name
        
        send_ping_to_device(fcm_project_id, package_name, params)
      rescue Exception => error
        log describe(error)
        log error.backtrace.join("\n")
        # Re-raise with the reason attached, because the message alone does not
        # carry one. PingJob collects what each client's ping raised and joins
        # the messages into the single error that reaches the resque log, and
        # google-api-client has already discarded everything FCM said about a
        # 401 by then: api_command.rb's check_status parses the error body only
        # `when 400, 402...500`, so 401 skips the parse and http_command.rb
        # falls back to the bare string "Unauthorized". That makes an iOS-only
        # THIRD_PARTY_AUTH_ERROR -- a missing or invalid APNs key on the
        # Firebase project, which fails Apple tokens while Android keeps
        # working -- indistinguishable from broken service-account credentials.
        #
        # Only Google's errors are rewrapped. InvalidProjectId,
        # InvalidPackageName and transport errors already say what went wrong,
        # and callers match on their classes.
        raise error.is_a?(Google::Apis::Error) ? FCMPingError.new(describe(error)) : error
      end
    end

    # The FCM errorCode is in the response body rather than the message, and
    # Google::Apis::Error keeps both alongside the status code.
    def self.describe(error)
      return error.message unless error.is_a?(Google::Apis::Error)

      described = "FCM ping failed: #{error.class.name.split('::').last} " \
                  "#{error.status_code} #{error.message}"
      described << " body=#{error.body}" unless error.body.to_s.empty?
      described
    end

    def self.send_ping_to_device(project_id,package_name,params)

      scope = Google::Apis::Messages::AUTH_MESSAGES
      authorization = Google::Auth.get_application_default(scope)
      
      service = Google::Apis::Messages::MessagesService.new(project_id: project_id)
      service.authorization = authorization
      
      service.notify(fcm_message(package_name,params))

    end

    def self.fcm_message(package_name,params)
      params.reject! {|k,v| v.nil? || v.length == 0}
      data = {}
      data['do_sync'] = params['sources'] ? params['sources'].join(',') : ''
      data['alert'] = params['message'] if params['message']
      data['vibrate'] = params['vibrate'] if params['vibrate']
      data['sound'] = params['sound'] if params['sound']
      data['phone_id'] = params['phone_id'] if params['phone_id']

      android = {}
      android['collapse_key'] = (rand * 100000000).to_i.to_s
      android['priority'] = 'high'
      android['restricted_package_name'] = package_name
      android['data'] = data
      # Only attach a notification when there is something to display. params
      # has already had its nil and empty values rejected above, so a ping with
      # no message would otherwise send `notification: {'body' => nil}`, and the
      # tray notification it asks for cannot be shown regardless.
      if params['message']
        android['notification'] = {}
        # android['notification']['title'] = 'Test message'
        android['notification']['body'] = params['message']
      end

      # google-api-fcm 0.1.9 is the gem's newest release and is not Ruby 3
      # compatible in two places, both of which have to be stepped around here.
      #
      # Message.new(token:, android:) reaches `MessageObject.new(hash)` at
      # classes.rb:56 -- a positional Hash into `def initialize(**args)`, which
      # Ruby 2 converted to keywords and Ruby 3 rejects with "wrong number of
      # arguments (given 1, expected 0)". Passing :message_object avoids it:
      # MessageObject#update! only calls initialize_build when that key is
      # absent, and constructing the MessageObject here passes real keywords.
      #
      # The representation then declares `hash :apns`, `hash :webpush` and
      # `hash :fcm_options` while MessageObject assigns them only when the key
      # is supplied, so omitting them renders nil and dies inside representable
      # with "undefined method 'each' for nil". Empty hashes serialize away.
      message_object = Google::Apis::Messages::MessageObject.new(
        token: params['device_pin'].to_s,
        android: android,
        apns: {},
        webpush: {},
        fcm_options: {}
      )

      Google::Apis::Messages::Message.new(message_object: message_object)
    end
  end
end
