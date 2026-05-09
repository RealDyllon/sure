require "test_helper"

class Provider::OpenaiViaCodex::AuthTest < ActiveSupport::TestCase
  setup do
    @tmpdir = Dir.mktmpdir
    @auth_path = File.join(@tmpdir, "auth.json")
  end

  teardown do
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  test "reads non-expired ChatGPT Codex auth token and account id" do
    write_auth(access_token: jwt(exp: 1.hour.from_now.to_i), account_id: "account-123")

    auth = Provider::OpenaiViaCodex::Auth.new(path: @auth_path)

    assert_equal [ JSON.parse(File.read(@auth_path)).dig("tokens", "access_token"), "account-123" ],
      auth.access_token_and_account_id
  end

  test "raises when auth file is missing" do
    auth = Provider::OpenaiViaCodex::Auth.new(path: File.join(@tmpdir, "missing.json"))

    error = assert_raises(Provider::OpenaiViaCodex::Auth::Error) do
      auth.access_token_and_account_id
    end

    assert_match(/Codex auth file not found/, error.message)
  end

  test "raises when auth mode is not ChatGPT" do
    File.write(@auth_path, { auth_mode: "api_key", tokens: { access_token: jwt(exp: 1.hour.from_now.to_i) } }.to_json)

    auth = Provider::OpenaiViaCodex::Auth.new(path: @auth_path)

    error = assert_raises(Provider::OpenaiViaCodex::Auth::Error) do
      auth.access_token_and_account_id
    end

    assert_match(/Expected auth_mode 'chatgpt'/, error.message)
  end

  test "refreshes expired access token and writes auth atomically with private permissions" do
    write_auth(access_token: jwt(exp: 1.minute.ago.to_i), refresh_token: "refresh-old", account_id: "account-123")

    auth = Provider::OpenaiViaCodex::Auth.new(path: @auth_path)
    auth.expects(:refresh_tokens).with("refresh-old").returns({
      "access_token" => "access-new",
      "refresh_token" => "refresh-new",
      "id_token" => "id-new"
    })

    assert_equal [ "access-new", "account-123" ], auth.access_token_and_account_id

    data = JSON.parse(File.read(@auth_path))
    assert_equal "access-new", data.dig("tokens", "access_token")
    assert_equal "refresh-new", data.dig("tokens", "refresh_token")
    assert_equal "id-new", data.dig("tokens", "id_token")
    assert_equal "600", (File.stat(@auth_path).mode & 0o777).to_s(8)
  end

  test "configured? is true only for existing ChatGPT auth with an access token" do
    auth = Provider::OpenaiViaCodex::Auth.new(path: @auth_path)
    assert_not auth.configured?

    write_auth(access_token: "token")
    assert auth.configured?

    File.write(@auth_path, { auth_mode: "api_key", tokens: { access_token: "token" } }.to_json)
    assert_not auth.configured?
  end

  private

    def write_auth(access_token:, refresh_token: "refresh-token", account_id: nil)
      payload = {
        auth_mode: "chatgpt",
        tokens: {
          access_token: access_token,
          refresh_token: refresh_token,
          account_id: account_id
        }.compact
      }
      File.write(@auth_path, JSON.pretty_generate(payload))
    end

    def jwt(exp:)
      header = Base64.urlsafe_encode64({ alg: "none" }.to_json, padding: false)
      payload = Base64.urlsafe_encode64({ exp: exp }.to_json, padding: false)
      "#{header}.#{payload}.signature"
    end
end
