require 'test_helper'

describe "OpenStack authentication" do
  before do
    @old_mock_value = Excon.defaults[:mock]
    Excon.defaults[:mock] = true
    Excon.stubs.clear

    @expires      = Time.now.utc + 600
    @token        = Fog::Mock.random_numbers(8).to_s
    @tenant_token = Fog::Mock.random_numbers(8).to_s

    @body = {
      "access" => {
        "token"          => {
          "expires" => @expires.iso8601,
          "id"      => @token,
          "tenant"  => {
            "enabled"     => true,
            "description" => nil,
            "name"        => "admin",
            "id"          => @tenant_token,
          }
        },
        "serviceCatalog" => [
          {
            "endpoints"       => [
              {
                "adminURL"    => "http://example:8774/v2/#{@tenant_token}",
                "region"      => "RegionOne",
                "internalURL" => "http://example:8774/v2/#{@tenant_token}",
                "id"          => Fog::Mock.random_numbers(8).to_s,
                "publicURL"   => "http://example:8774/v2/#{@tenant_token}"
              }
            ],
            "endpoints_links" => [],
            "type"            => "compute",
            "name"            => "nova"
          },
          {
            "endpoints"       => [
              {
                "adminURL"    => "http://example:9292",
                "region"      => "RegionOne",
                "internalURL" => "http://example:9292",
                "id"          => Fog::Mock.random_numbers(8).to_s,
                "publicURL"   => "http://example:9292"
              }
            ],
            "endpoints_links" => [],
            "type"            => "image",
            "name"            => "glance"
          }
        ],
        "user"           => {
          "username"    => "admin",
          "roles_links" => [],
          "id"          => Fog::Mock.random_numbers(8).to_s,
          "roles"       => [
            {"name" => "admin"},
            {"name" => "KeystoneAdmin"},
            {"name" => "KeystoneServiceAdmin"}
          ],
          "name"        => "admin"
        },
        "metadata"       => {
          "is_admin" => 0,
          "roles"    => [
            Fog::Mock.random_numbers(8).to_s,
            Fog::Mock.random_numbers(8).to_s,
            Fog::Mock.random_numbers(8).to_s
          ]
        }
      }
    }
  end

  it "with v2" do
    Excon.stub(
      {:method => 'POST', :path => "/v2.0/tokens"},
      {:status => 200, :body => Fog::JSON.encode(@body)}
    )

    expected = {
      :user                     => @body['access']['user'],
      :tenant                   => @body['access']['token']['tenant'],
      :identity_public_endpoint => nil,
      :server_management_url    => @body['access']['serviceCatalog'].
                                     first['endpoints'].first['publicURL'],
      :token                    => @token,
      :expires                  => @expires.iso8601,
      :current_user_id          => @body['access']['user']['id'],
      :unscoped_token           => @token
    }

    assert(expected) do
      Fog::OpenStack.authenticate_v2(
        :openstack_auth_uri     => URI('http://example/v2.0/tokens'),
        :openstack_tenant       => 'admin',
        :openstack_service_type => %w[compute]
      )
    end
  end

  it "validates token" do
    old_credentials = Fog.credentials
    Fog.credentials = {:openstack_auth_url => 'http://openstack:35357/v2.0/tokens'}
    identity = Fog::Identity[:openstack]
    identity.validate_token(@token, @tenant_token)
    identity.validate_token(@token)
    Fog.credentials = old_credentials
  end

  it "checks token" do
    old_credentials = Fog.credentials
    Fog.credentials = {:openstack_auth_url => 'http://openstack:35357/v2.0/tokens'}
    identity = Fog::Identity[:openstack]
    identity.check_token(@token, @tenant_token)
    identity.check_token(@token)
    Fog.credentials = old_credentials
  end

  it "v2 missing service" do
    Excon.stub(
      {:method => 'POST', :path => "/v2.0/tokens"},
      {:status => 200, :body => Fog::JSON.encode(@body)}
    )

    proc do
      Fog::OpenStack.authenticate_v2(
        :openstack_auth_uri     => URI('http://example/v2.0/tokens'),
        :openstack_tenant       => 'admin',
        :openstack_service_type => %w[network]
      )
    end.must_raise Fog::Errors::NotFound, 'Could not find service network.  Have compute, image'
  end

  it "v2 missing storage service" do
    Excon.stub(
      {:method => 'POST', :path => "/v2.0/tokens"},
      {:status => 200, :body => Fog::JSON.encode(@body)}
    )

    proc do
      Fog::OpenStack.authenticate_v2(
        :openstack_auth_uri     => URI('http://example/v2.0/tokens'),
        :openstack_tenant       => 'admin',
        :openstack_service_type => 'object-store'
      )
    end.must_raise NoMethodError, "undefined method `join' for \"object-store\":String"

    proc do
      Fog::OpenStack.authenticate_v2(
        :openstack_auth_uri     => URI('http://example/v2.0/tokens'),
        :openstack_tenant       => 'admin',
        :openstack_service_type => %w[object-store]
      )
    end.must_raise Fog::Errors::NotFound, "Could not find service object-store.  Have compute, image"
  end

  it "v2 auth with two compute services" do
    body_clone = @body.clone
    body_clone["access"]["serviceCatalog"] <<
      {
        "endpoints"       => [
          {
            "adminURL"    => "http://example2:8774/v2/#{@tenant_token}",
            "region"      => "RegionOne",
            "internalURL" => "http://example2:8774/v2/#{@tenant_token}",
            "id"          => Fog::Mock.random_numbers(8).to_s,
            "publicURL"   => "http://example2:8774/v2/#{@tenant_token}"
          }
        ],
        "endpoints_links" => [],
        "type"            => "compute",
        "name"            => "nova2"
      }

    Excon.stub(
      {:method => 'POST', :path => "/v2.0/tokens"},
      {:status => 200, :body => Fog::JSON.encode(body_clone)}
    )

    assert("http://example2:8774/v2/#{@tenant_token}") do
      Fog::OpenStack.authenticate_v2(
        :openstack_auth_uri     => URI('http://example/v2.0/tokens'),
        :openstack_tenant       => 'admin',
        :openstack_service_type => %w[compute],
        :openstack_service_name => 'nova2')[:server_management_url]
    end
  end

  it "legacy v1 auth" do
    headers = {
      "X-Storage-Url"  => "https://swift.myhost.com/v1/AUTH_tenant",
      "X-Auth-Token"   => "AUTH_yui193bdc00c1c46c5858788yuio0e1e2p",
      "X-Trans-Id"     => "iu99nm9999f9b999c9b999dad9cd999e99",
      "Content-Length" => "0",
      "Date"           => "Wed, 07 Aug 2013 11:11:11 GMT"
    }

    Excon.stub(
      {:method => 'GET', :path => "/auth/v1.0"},
      {:status => 200, :body => "", :headers => headers}
    )

    assert("https://swift.myhost.com/v1/AUTH_tenant") do
      Fog::OpenStack.authenticate_v1(
        :openstack_auth_uri     => URI('https://swift.myhost.com/auth/v1.0'),
        :openstack_username     => 'tenant:dev',
        :openstack_api_key      => 'secret_key',
        :openstack_service_type => %w[storage])[:server_management_url]
    end
  end

  after do
    Excon.stubs.clear
    Excon.defaults[:mock] = @old_mock_value
  end
end
