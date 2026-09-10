class AgentNotifications::VehiclePartsEscalationMailer < ApplicationMailer
  def escalation_notification(emails:, conversation:, customer_data: nil, message: nil)
    @conversation = conversation
    @account = conversation.account
    @dealership_name = conversation.account.name
    @customer_data = customer_data || {}
    @last_incoming_message = message
    ensure_current_account(@account)

    recipients = @account.suspended? ? super_admin_emails(@account) : emails
    recipients = exclude_unsubscribed(recipients, @account)

    return if recipients.blank? && default_bcc_emails.blank?

    @summary = conversation_summary
    @customer_name = @customer_data['name'].presence || @conversation.contact.name
    @customer_email = @customer_data['email'].presence
    @customer_phone = PhoneNumberFormatter.format(@customer_data['phone'].presence)
    @platform_name = @conversation.inbox.platform_name
    @action_url = conversation_url(@conversation)

    subject = '[Vehicle Parts Escalation] 🚨 Customer request needs attention'

    add_unsubscribe_headers!
    mail(to: recipients, subject: subject, bcc: default_bcc_emails.presence)
  end

  private

  def conversation_summary
    Conversations::SummaryService.new(conversation: @conversation).perform
    @conversation.summary
  end

  def conversation_url(conversation)
    "#{ENV.fetch('FRONTEND_URL',
                 nil)}/app/accounts/#{conversation.account_id}/inbox/#{conversation.inbox_id}/conversations/#{conversation.display_id}"
  end
end
