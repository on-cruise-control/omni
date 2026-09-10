class AgentNotifications::BookingMailer < ApplicationMailer
  def booking_notification(emails:, conversation:, booking_date:, phone:, email:, whatsapp_number: nil, text_number: nil, summary: nil,
                           source: nil, campaign: nil, search_term: nil, content_variant: nil, ad_title: nil)
    @conversation = conversation
    @account = conversation.account
    ensure_current_account(@account)

    if summary.present?
      @summary = summary
    else
      begin
        Conversations::SummaryService.new(conversation: @conversation, force_refresh: true).perform
      rescue StandardError
        nil
      end
      @conversation.reload
      @summary = @conversation.summary
    end

    # If account is suspended, send to SuperAdmins only
    recipients = if @account.suspended?
                   super_admin_emails(@account)
                 else
                   emails
                 end
    recipients = exclude_unsubscribed(recipients, @account)

    return if recipients.blank? && default_bcc_emails.blank?

    @booking_date = booking_date
    @phone = PhoneNumberFormatter.format(phone)
    @customer_email = email
    @whatsapp_number = PhoneNumberFormatter.format(whatsapp_number)
    @text_number = PhoneNumberFormatter.format(text_number)
    @platform_name = @conversation&.inbox&.platform_name
    @instagram_profile_url = instagram_profile_url(@conversation)
    @source = source
    @campaign = campaign
    @search_term = search_term
    @content_variant = content_variant
    @ad_title = ad_title
    subject = '[Sales] New booking scheduled 📆'

    add_unsubscribe_headers!
    mail(to: recipients, subject: subject, bcc: default_bcc_emails.presence)
  end
end
