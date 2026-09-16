require File.join(File.dirname(__FILE__),'..','spec_helper')

describe "Ping Apple" do
  include_examples "SharedRhoconnectHelper", :rhoconnect_data => false

  # An ES256 key of the same shape as the .p8 Apple issues, generated per run so
  # no credential lives in the repo.
  APNS_TEST_KEY = OpenSSL::PKey::EC.generate('prime256v1').to_pem

  before do
    @params = {"user_id" => @u.id, "api_token" => @api_token,
      "sources" => [@s.name], "message" => 'hello world',
      "vibrate" => '5', "badge" => '5', "sound" => 'hello.mp3',
      "device_pin" => @c.device_pin, "device_port" => @c.device_port}

    allow(Rhoconnect::Apple).to receive(:get_config).and_return(
      :test => {
        :apns_auth_key => 'spec/apns_key.p8',
        :apns_key_id   => 'ABC123DEFG',
        :apns_team_id  => 'TEAM123456',
        :apns_topic    => 'com.example.app',
        :apns_host     => Rhoconnect::Apple::SANDBOX_HOST
      }
    )
    allow(Rhoconnect::Apple).to receive(:auth_key).and_return(APNS_TEST_KEY)

    @sent = nil
    @client = double('net_http2_client')
    allow(@client).to receive(:close)
    allow(NetHttp2::Client).to receive(:new).and_return(@client)
    allow(@client).to receive(:call) do |_verb, path, opts|
      @sent = { :path => path, :body => JSON.parse(opts[:body]), :headers => opts[:headers] }
      double('response', :status => '200', :body => '')
    end
  end

  it "should ping apple" do
    Apple.ping(@params)
    expect(@sent[:path]).to eq("/3/device/#{@c.device_pin}")
  end

  it "should log deprecation on iphone ping" do
    expect(Iphone).to receive(:log).once.with("DEPRECATION WARNING: 'iphone' is a deprecated device_type, use 'apple' instead")
    Iphone.ping(@params)
  end

  it "should authenticate with an ES256 provider token" do
    Apple.ping(@params)

    scheme, token = @sent[:headers]['authorization'].split(' ')
    expect(scheme).to eq('bearer')

    header = JSON.parse(Base64.urlsafe_decode64(token.split('.').first + '=='))
    expect(header['alg']).to eq('ES256')
    expect(header['kid']).to eq('ABC123DEFG')

    claims, = JWT.decode(token, OpenSSL::PKey.read(APNS_TEST_KEY), true, :algorithm => 'ES256')
    expect(claims['iss']).to eq('TEAM123456')
    expect(claims['iat']).to be_within(60).of(Time.now.to_i)

    expect(@sent[:headers]['apns-topic']).to eq('com.example.app')
  end

  it "should send an alert push when there is a message" do
    Apple.ping(@params)
    expect(@sent[:headers]['apns-push-type']).to eq('alert')
    expect(@sent[:headers]['apns-priority']).to eq('10')
  end

  # APNs rejects priority 10 on a background push, so the pairing matters.
  it "should send a background push at priority 5 when there is no message" do
    Apple.ping(@params.merge('message' => ''))
    expect(@sent[:headers]['apns-push-type']).to eq('background')
    expect(@sent[:headers]['apns-priority']).to eq('5')
  end

  it "should compute apn_message" do
    expect(Apple.apn_message(@params)).to eq(
      'aps' => {
        'alert' => 'hello world', 'badge' => 5, 'sound' => 'hello.mp3',
        'vibrate' => '5', 'content-available' => 1
      },
      'do_sync' => 'SampleAdapter'
    )
  end

  # The binary implementation sent the raw Array here, which the device could
  # not split -- so even a delivered ping could not start a sync.
  it "should compute apn_message with source array" do
    @params['sources'] << 'SimpleAdapter'
    expect(Apple.apn_message(@params)['do_sync']).to eq('SampleAdapter,SimpleAdapter')
  end

  it "should skip a device APNs reports as no longer valid" do
    allow(@client).to receive(:call).and_return(
      double('response', :status => '400', :body => '{"reason":"BadDeviceToken"}')
    )
    expect(Apple).to receive(:log).once.with(/no longer valid \(BadDeviceToken\)/)
    expect { Apple.ping(@params) }.not_to raise_error
  end

  it "should raise on an APNs failure that is not device specific" do
    allow(@client).to receive(:call).and_return(
      double('response', :status => '403', :body => '{"reason":"InvalidProviderToken"}')
    )
    expect(Apple).to receive(:log).once
    expect { Apple.ping(@params) }.to raise_error(Apple::ApnsError, /403 InvalidProviderToken/)
  end

  it "should close the connection even when the call raises" do
    allow(@client).to receive(:call).and_raise(SocketError.new('socket error'))
    expect(@client).to receive(:close).once
    expect { Apple.ping(@params) }.to raise_error(SocketError)
  end

  it "should do nothing if the APNs settings are incomplete" do
    allow(Rhoconnect::Apple).to receive(:get_config).and_return(:test => { :apns_key_id => 'ABC123DEFG' })
    allow(Rhoconnect::Apple).to receive(:auth_key).and_return(nil)
    expect(NetHttp2::Client).to receive(:new).exactly(0).times
    expect(Apple).to receive(:log).twice
    Apple.ping(@params)
  end

  it "should do nothing if the client has no device_pin" do
    expect(NetHttp2::Client).to receive(:new).exactly(0).times
    expect(Apple).to receive(:log).once.with(/no device_pin/)
    Apple.ping(@params.merge('device_pin' => ''))
  end
end
