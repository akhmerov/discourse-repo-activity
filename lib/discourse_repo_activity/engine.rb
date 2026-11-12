# frozen_string_literal: true

module ::DiscourseRepoActivity
  class Engine < ::Rails::Engine
    engine_name PLUGIN_NAME
    isolate_namespace DiscourseRepoActivity
  end
end
