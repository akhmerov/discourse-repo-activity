# frozen_string_literal: true

RSpec.describe DiscourseRepoActivity::Bot do
  it "creates the bot when seed fixtures did not run" do
    PluginStore.remove(DiscourseRepoActivity::PLUGIN_NAME, "bot_user_id")

    bot = described_class.user

    expect(bot).to be_persisted
    expect(bot.id).to be < 0
    expect(described_class.user).to eq(bot)
  end

  it "replaces a bot whose user was deleted" do
    old = described_class.ensure!
    old.destroy!

    bot = described_class.user

    expect(bot).to be_persisted
    expect(PluginStore.get(DiscourseRepoActivity::PLUGIN_NAME, "bot_user_id")).to eq(bot.id)
  end
end
