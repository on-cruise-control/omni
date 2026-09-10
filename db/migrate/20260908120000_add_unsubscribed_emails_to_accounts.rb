class AddUnsubscribedEmailsToAccounts < ActiveRecord::Migration[7.1]
  def change
    add_column :accounts, :unsubscribed_emails, :jsonb, default: []
  end
end
