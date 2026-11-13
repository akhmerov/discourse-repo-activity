# frozen_string_literal: true

module DiscourseRepoActivity
  module Signature
    def self.valid?(connection, body, headers)
      if connection.forge == "github"
        supplied = headers["X-Hub-Signature-256"].to_s
        expected = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", connection.secret, body)
      else
        supplied = headers["X-Gitlab-Token"].to_s
        expected = connection.secret
      end
      supplied.bytesize == expected.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(supplied, expected)
    end
  end
end
