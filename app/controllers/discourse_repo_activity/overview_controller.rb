# frozen_string_literal: true

module DiscourseRepoActivity
  class OverviewController < ::ApplicationController
    requires_plugin PLUGIN_NAME
    requires_login

    def index
      ids = params.require(:channel_ids)
      if !ids.is_a?(Array) || ids.length > 200 ||
           ids.any? { |id| !id.to_s.match?(/\A[1-9][0-9]*\z/) }
        raise Discourse::InvalidParameters
      end
      response.headers["Cache-Control"] = "no-store"
      render json: { channels: Overview.for(ids.map(&:to_i).uniq, current_user) }
    end
  end
end
