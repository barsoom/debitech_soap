require 'stringio'
$previous_stderr = $stderr
$stderr = StringIO.new
require 'soap/wsdlDriver'
$stderr = $previous_stderr
require 'ostruct'
require 'debitech_soap/string_extensions'

module DebitechSoap
  class API

    RETURN_DATA = %w{aCSUrl acquirerAddress acquirerAuthCode acquirerAuthResponseCode acquirerCity acquirerConsumerLimit acquirerErrorDescription acquirerFirstName acquirerLastName acquirerMerchantLimit acquirerZipCode amount errorMsg infoCode infoDescription pAReqMsg resultCode resultText verifyID}

    PARAMS = { %w(settle)                     => ["verifyID", "transID", "amount", "extra"],
               %w(subscribeAndSettle subscribe_and_settle) \
                                              => ["verifyID", "transID", "data", "ip", "extra"],
               %w(authorize)                  => ["billingFirstName", "billingLastName", "billingAddress", "billingCity",
                                                  "billingCountry", "cc", "expM", "expY", "eMail", "ip", "data", "currency", "transID", "extra"],
               %w(authorizeAndSettle3DS authorize_and_settle_3ds) \
                                              => ["verifyID", "paRes", "extra"],
               %w(refund)                     => ["verifyID", "transID", "amount", "extra"],
               %w(askIf3DSEnrolled ask_if_3ds_enrolled) \
                                              => ["billingFirstName", "billingLastName", "billingAddress", "billingCity",
                                                  "billingCountry", "cc", "expM", "expY", "eMail", "ip", "data", "currency", "transID",
                                                  "httpAcceptHeader", "httpUserAgentHeader", "method", "referenceNo", "extra"],
               %w(authReversal auth_reversal) => ["verifyID", "amount", "transID", "extra"],
               %w(authorize3DS authorize_3ds) => ["verifyID", "paRes", "extra"],
               %w(subscribe)                  => ["verifyID", "transID", "data", "ip", "extra"],
               %w(authorizeAndSettle authorize_and_settle) \
                                              => ["billingFirstName", "billingLastName", "billingAddress", "billingCity", "billingCountry",
                                                  "cc", "expM", "expY", "eMail", "ip", "data", "currency", "transID", "extra"] }

    def initialize(opts = {})
      @api_credentials = {}
      @api_credentials[:shopName] = opts[:merchant]
      @api_credentials[:userName] = opts[:username]
      @api_credentials[:password] = opts[:password]

      disable_stderr do
        @client = SOAP::WSDLDriverFactory.new(File.join(File.dirname(__FILE__), "../service.wsdl")).create_rpc_driver
      end

      # Uncomment this line if you want to see the request and response printed to STDERR.
      #@client.wiredump_dev = STDERR

      # Enable changing supported ciphers, for deprecation situations like http://tech.dibspayment.com/nodeaddpage/listofapprovedciphersuites.
      # This lets us easily experiment in development, and to do quick changes in production if we must.
      dibs_httpclient_ciphers = ENV["DIBS_HTTPCLIENT_CIPHERS"]
      if dibs_httpclient_ciphers
        httpclient_instance = @client.streamhandler.client
        httpclient_instance.ssl_config.ciphers = dibs_httpclient_ciphers
      end

      define_java_wrapper_methods!
    end

    def valid_credentials?
      disable_stderr do
        # We make a "refund" request, but we make sure to set the amount to 0 and to enter a verify ID that will never match a real one.
        # Previously, we'd confirm credentials with the safer checkSwedishPersNo call, but that seems broken now (always returns false).
        response_value = return_value(@client.refund(@api_credentials.merge({ :verifyID => -1, :amount => 0 })))
        result_text = response_value.resultText

        case result_text
        when "error_transID_or_verifyID"
          # The auth succeeded, but the refund (thankfully and intentionally) did not.
          true
        when "336 web_service_login_failed"
          # The auth is wrong.
          false
        else
          raise "Unexpected result text: #{result_text.inspect}"
        end
      end
    end

  private

    # We use mumboe-soap4r for Ruby 1.9 compatibility, but if you use this library in 1.8 without using that lib
    # (e.g. without bundle exec) then you might get the standard library SOAP lib instead.
    # The standard library SOAP lib uses "return" here, and mumboe-soap4r uses "m_return".
    def return_value(object)
      object.respond_to?(:m_return) ? object.m_return : object.return
    end

    def define_java_wrapper_methods!
      PARAMS.keys.flatten.each { |method|
        (class << self; self; end).class_eval do                          # Doc:
          define_method(method) do |*args|                                # def refund(*args)
            attributes = @api_credentials.clone

            if args.first.is_a?(Hash) 
              attributes.merge!(args.first)
            else
              parameter_order = api_signature(method).last
              args.each_with_index { |argument, i|
                attributes[parameter_order[i].to_sym] = argument
              }
            end            
            begin
              client_result = return_value(@client.send(api_signature(method).first.first, attributes))
            rescue Timeout::Error
              client_result = OpenStruct.new(:resultCode => 403, :resultText => "SOAP Timeout")
              return return_data(client_result)
            end
            return_data(client_result)
          end
        end
      }
    end

    def return_data(results)
      hash = {}

      RETURN_DATA.each { |attribute|
        result = results.send(attribute)
        unless result.is_a?(SOAP::Mapping::Object)
          result = result.to_i if integer?(result)
          hash[attribute] = result
          hash["get_" + attribute.underscore] = result
          hash["get" + attribute.camelcase] = result
          hash[attribute.underscore] = result
        end
      }
      OpenStruct.new(hash)
    end

    def integer?(result)
      result.to_i != 0 || result == "0"
    end

    def disable_stderr
      begin
        $stderr = File.open('/dev/null', 'w')
        yield
      ensure
        $stderr = STDERR
      end
    end

    def api_signature(method)
      PARAMS.find {|key,value| key.include?(method.to_s) }
    end

  end
end
