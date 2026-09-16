require File.join(File.dirname(__FILE__), '..', 'spec_helper')

describe "Ping Android FCM" do
  include_examples "SharedRhoconnectHelper", :rhoconnect_data => false

  before(:each) do
    allow( Google::Auth).to receive(:get_application_default)
    @params = {"device_pin" => @c.device_pin,
               "sources" => [@s.name], "message" => 'hello world',
               "vibrate" => '5', "badge" => '5', "sound" => 'hello.mp3'}
    @response = double('response')
    Rhoconnect.settings[:fcm_project_id] = 'valid_project_id'
    Rhoconnect.settings[:package_name] = 'valid_package_name'
  end

  it "should ping fcm successfully" do
    stub_request(:post, "https://fcm.googleapis.com/v1/projects/valid_project_id/messages:send").with { |request|
      hash = JSON.parse request.body
      valid = hash["message"]["token"] == "abcd"
      valid = valid && hash["message"]["topic"] == nil
      valid = valid && hash["message"]["android"]["restricted_package_name"] == "valid_package_name"
      valid
    }
    Fcm.ping(@params)
  end

  it "should raise error on missing fcm_project_id setting" do
    key = Rhoconnect.settings[:fcm_project_id.dup]
    Rhoconnect.settings[:fcm_project_id] = nil
    expect(lambda { Fcm.ping(@params) }).to raise_error(Fcm::InvalidProjectId, 'Missing `:fcm_project_id:` option in settings/settings.yml')
    Rhoconnect.settings[:fcm_project_id] = key
  end

  it "should raise error on missing package_name setting" do
    key = Rhoconnect.settings[:package_name.dup]
    Rhoconnect.settings[:package_name] = nil
    expect(lambda { Fcm.ping(@params) }).to raise_error(Fcm::InvalidPackageName, 'Missing `:package_name:` option in settings/settings.yml')
    Rhoconnect.settings[:package_name] = key
  end

  it "should ping fcm with 503 connection error" do
    stub_request(:post, "https://fcm.googleapis.com/v1/projects/valid_project_id/messages:send").to_raise(RestClient::Exception.new(nil,503))
    expect(lambda { Fcm.ping(@params) }).to raise_error(RestClient::Exception)
  end

  # google-api-client renders every 401 as the bare word "Unauthorized":
  # api_command.rb's check_status parses the error body only `when 400,
  # 402...500`, so 401 never reaches the parse. PingJob joins these messages
  # into the one error that reaches the resque log, so without the body the log
  # cannot distinguish THIRD_PARTY_AUTH_ERROR -- a missing or invalid APNs key
  # on the Firebase project, which fails Apple tokens while Android succeeds --
  # from service-account credentials that are simply wrong.
  it "should keep the FCM errorCode when FCM answers 401" do
    body = {
      'error' => {
        'code' => 401,
        'message' => 'Auth error from APNS or Web Push Service',
        'status' => 'UNAUTHENTICATED',
        'details' => [{
          '@type' => 'type.googleapis.com/google.firebase.fcm.v1.FcmError',
          'errorCode' => 'THIRD_PARTY_AUTH_ERROR'
        }]
      }
    }.to_json
    stub_request(:post, "https://fcm.googleapis.com/v1/projects/valid_project_id/messages:send")
      .to_return(:status => 401, :body => body, :headers => { 'Content-Type' => 'application/json' })

    expect { Fcm.ping(@params) }.to raise_error(Fcm::FCMPingError, /THIRD_PARTY_AUTH_ERROR/)
  end

  it "should report the status code and class for an FCM 401" do
    stub_request(:post, "https://fcm.googleapis.com/v1/projects/valid_project_id/messages:send")
      .to_return(:status => 401, :body => '')

    expect { Fcm.ping(@params) }.to raise_error(
      Fcm::FCMPingError, 'FCM ping failed: AuthorizationError 401 Unauthorized'
    )
  end

  xit "should ping fcm with 200 error message" do
    allow( Google::Auth).to receive(:get_application_default)

    error = 'error:DeviceMessageRateExceeded'
    allow(@response).to receive(:code).and_return(200)
    allow(@response).to receive(:body).and_return(error)
    allow(@response).to receive(:headers).and_return(nil)
    stub_request(:post, "https://fcm.googleapis.com/v1/projects/valid_project_id/messages:send").to_raise(RestClient::Exception.new(@response,200))
    expect(lambda { Fcm.ping(@params) }).to raise_error(Fcm::FCMPingError, "FCM ping error: DeviceMessageRateExceeded")
  end

  xit "should fail to ping with bad authentication" do
    error = 'Error=BadAuthentication'
    allow(@response).to receive(:code).and_return(403)
    allow(@response).to receive(:body).and_return(error)
    allow(@response).to receive(:headers).and_return({})
    setup_post_yield(@response)
    expect(Fcm).to receive(:log).twice
    expect(lambda { Fcm.ping(@params) }).to raise_error(
                                                Fcm::InvalidProjectId, "Invalid FCM project id. Obtain new api key from FCM service."
                                            )
  end

  xit "should ping fcm with 401 error message" do
    allow(@response).to receive(:code).and_return(401)
    allow(@response).to receive(:body).and_return('')
    setup_post_yield(@response)
    expect(Fcm).to receive(:log).twice
    expect(lambda { Fcm.ping(@params) }).to raise_error(
                                                Fcm::InvalidProjectId, "Invalid FCM project id. Obtain new api key from FCM service."
                                            )
  end

  # These build the message for real rather than stubbing Message.new. Stubbing
  # the constructor is what let google-api-fcm's two Ruby 3 incompatibilities
  # ship unnoticed: every ping failed in the field with "wrong number of
  # arguments (given 1, expected 0)" while this suite stayed green.
  it "should compute fcm_message" do
    message = Fcm.fcm_message(Rhoconnect.settings[:package_name], @params)
    android = message.message_object.android

    expect(message.message_object.token).to eq(@c.device_pin)
    expect(android["priority"]).to eq("high")
    expect(android["restricted_package_name"]).to eq(Rhoconnect.settings[:package_name])
    expect(android["data"]["do_sync"]).to eq(@s.name)
    expect(android["data"]["alert"]).to eq("hello world")
    expect(android["data"]["vibrate"]).to eq("5")
    expect(android["data"]["sound"]).to eq("hello.mp3")
    expect(android["notification"]["body"]).to eq("hello world")
  end

  it "should trim empty or nil params from fcm_message" do
    params = {
        "device_pin" => @c.device_pin,
        "sources" => [],
        "message" => '',
        "vibrate" => '5',
        "sound" => 'hello.mp3'
    }

    message = Fcm.fcm_message(Rhoconnect.settings[:package_name], params)
    android = message.message_object.android

    expect(message.message_object.token).to eq(@c.device_pin)
    expect(android["priority"]).to eq("high")
    expect(android["restricted_package_name"]).to eq(Rhoconnect.settings[:package_name])
    expect(android["data"]["do_sync"]).to eq('')
    expect(android["data"]["alert"]).to eq(nil)
    expect(android["data"]["vibrate"]).to eq("5")
    expect(android["data"]["sound"]).to eq("hello.mp3")
    # An empty message leaves nothing to display, so no notification is sent.
    expect(android).not_to have_key("notification")
  end

  # The second incompatibility: the representation declares `hash :apns`,
  # `hash :webpush` and `hash :fcm_options`, so a MessageObject built without
  # them renders nil and dies in representable. Only serializing catches it.
  it "should render fcm_message as FCM v1 JSON" do
    message = Fcm.fcm_message(Rhoconnect.settings[:package_name], @params)
    json = JSON.parse(Google::Apis::Messages::Message::Representation.new(message).to_json)

    expect(json["message"]["token"]).to eq(@c.device_pin)
    expect(json["message"]["topic"]).to be_nil
    expect(json["message"]["android"]["restricted_package_name"]).to eq(Rhoconnect.settings[:package_name])
    expect(json["message"]["android"]["data"]["do_sync"]).to eq(@s.name)
  end
end
