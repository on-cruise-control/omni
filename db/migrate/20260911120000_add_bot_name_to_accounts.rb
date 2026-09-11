class AddBotNameToAccounts < ActiveRecord::Migration[7.1]
  def change
    add_column :accounts, :bot_name, :string
  end
end
