class Webhooks::PostmarkController < ActionController::API
  before_action :verify_secret!

  ESCALATION_EMAIL_COLUMNS = %w[
    escalation_emails
    sales_escalation_emails
    service_escalation_emails
    vehicle_parts_escalation_emails
    booking_emails
    service_emails
    vehicle_parts_emails
  ].freeze

  def events
    handle_subscription_change if params[:RecordType] == 'SubscriptionChange'
    head :ok
  end

  private

  def handle_subscription_change
    email = params[:Recipient].presence
    return if email.blank?

    if ActiveModel::Type::Boolean.new.cast(params[:SuppressSending])
      add_unsubscribed_email(email)
    else
      remove_unsubscribed_email(email)
    end
  end

  def add_unsubscribed_email(email)
    json_email = [email].to_json

    accounts_with_escalation_email(email)
      .where.not('unsubscribed_emails @> ?', json_email)
      .update_all(
        Account.sanitize_sql_array(["unsubscribed_emails = COALESCE(unsubscribed_emails, '[]'::jsonb) || ?::jsonb", json_email])
      )
  end

  def remove_unsubscribed_email(email)
    accounts_with_unsubscribed_email(email)
      .update_all(
        Account.sanitize_sql_array(['unsubscribed_emails = unsubscribed_emails - ?', email])
      )
  end

  def accounts_with_escalation_email(email)
    conditions = ESCALATION_EMAIL_COLUMNS.map { |column| "#{column} @> :email" }.join(' OR ')
    Account.where(conditions, email: [email].to_json)
  end

  def accounts_with_unsubscribed_email(email)
    Account.where('unsubscribed_emails @> :email', email: [email].to_json)
  end

  def verify_secret!
    secret = GlobalConfigService.load('POSTMARK_WEBHOOK_SECRET', nil)
    return head :unauthorized if secret.blank?

    header_secret = request.headers['Postmark-Webhook-Secret']
    return head :unauthorized if header_secret.blank?

    head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(secret, header_secret)
  end
end
