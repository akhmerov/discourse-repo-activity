# frozen_string_literal: true

module RepoActivitySpecHelpers
  def repo_payload(name)
    JSON.parse(File.read(File.join(__dir__, "fixtures", "#{name}.json")))
  end

  def repo_parse(connection, name, event, changes = {})
    DiscourseRepoActivity::Parser.new(
      connection,
      repo_payload(name).deep_merge(changes)
    ).parse(event)
  end

  def repo_process(connection, data)
    connection.with_lock do
      DiscourseRepoActivity::Processor.new(connection).process(data)
      connection.save!
    end
  end
end

RSpec.configure { |config| config.include RepoActivitySpecHelpers }
