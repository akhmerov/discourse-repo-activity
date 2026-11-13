# frozen_string_literal: true

module DiscourseRepoActivity
  class Ref < ActiveRecord::Base
    self.table_name = "repo_activity_refs"
    belongs_to :connection
    validates :kind, inclusion: { in: %w[branch pr] }
    validates :ci_state, inclusion: { in: %w[none pending running success failed neutral] }
  end
end
