# frozen_string_literal: true

class UpdateStatusService < BaseService
  include Redisable

  def call(status, account_id, options = {})
    @status                    = status
    @options                   = options
    @account_id                = account_id
    @media_attachments_changed = false
    @poll_changed              = false

    Status.transaction do
      create_previous_edit!
      update_media_attachments!
      update_poll!
      update_immediate_attributes!
      create_edit!
    end

    queue_poll_notifications!
    reset_preview_card!
    update_metadata!
    broadcast_updates!

    @status
  end

  private

  def update_media_attachments!
    previous_media_attachments = @status.media_attachments.to_a
    next_media_attachments     = validate_media!
    removed_media_attachments  = previous_media_attachments - next_media_attachments
    added_media_attachments    = next_media_attachments - previous_media_attachments

    MediaAttachment.where(id: removed_media_attachments.map(&:id)).update_all(status_id: nil)
    MediaAttachment.where(id: added_media_attachments.map(&:id)).update_all(status_id: @status.id)

    @status.media_attachments.reload
    @media_attachments_changed = true if removed_media_attachments.any? || added_media_attachments.any?
  end

  def validate_media!
    return [] if @options[:media_ids].blank? || !@options[:media_ids].is_a?(Enumerable)

    raise Mastodon::ValidationError, I18n.t('media_attachments.validations.too_many') if @options[:media_ids].size > 4 || @options[:poll].present?

    media_attachments = @status.account.media_attachments.where(status_id: [nil, @status.id]).where(scheduled_status_id: nil).where(id: @options[:media_ids].take(4).map(&:to_i)).to_a

    raise Mastodon::ValidationError, I18n.t('media_attachments.validations.images_and_video') if media_attachments.size > 1 && media_attachments.find(&:audio_or_video?)
    raise Mastodon::ValidationError, I18n.t('media_attachments.validations.not_ready') if media_attachments.any?(&:not_processed?)

    media_attachments
  end

  def update_poll!
    previous_poll        = @status.preloadable_poll
    @previous_expires_at = previous_poll&.expires_at

    if @options[:poll].present?
      poll = previous_poll || @status.account.polls.new(status: @status, votes_count: 0)

      # If for some reasons the options were changed, it invalidates all previous
      # votes, so we need to remove them
      if @options[:poll][:options] != poll.options
        @poll_changed = true
        poll.votes.delete_all unless poll.new_record?
      end

      poll.options     = @options[:poll][:options]
      poll.hide_totals = @options[:poll][:hide_totals] || false
      poll.multiple    = @options[:poll][:multiple] || false
      poll.expires_in  = @options[:poll][:expires_in]
      poll.save!

      @status.poll_id = poll.id
    elsif previous_poll.present?
      previous_poll.destroy
      @poll_changed = true
      @status.poll_id = nil
    end
  end

  def update_immediate_attributes!
    @status.text         = @options[:text].presence || @options.delete(:spoiler_text) || ''
    @status.spoiler_text = @options[:spoiler_text] || ''
    @status.sensitive    = @options[:sensitive] || @options[:spoiler_text].present?
    @status.language     = language_from_option || @status.language
    @status.edited_at    = Time.now.utc

    @status.save!
  end

  def language_from_option
    ISO_639.find(@options[:language])&.alpha2
  end

  def reset_preview_card!
    return unless @status.text_previously_changed?

    @status.preview_cards.clear
    LinkCrawlWorker.perform_async(@status.id)
  end

  def update_metadata!
    ProcessHashtagsService.new.call(@status)
    ProcessMentionsService.new.call(@status)
  end

  def broadcast_updates!
    DistributionWorker.perform_async(@status.id, { 'update' => true })
    ActivityPub::StatusUpdateDistributionWorker.perform_async(@status.id)
  end

  def queue_poll_notifications!
    poll = @status.preloadable_poll

    # If the poll had no expiration date set but now has, or now has a sooner
    # expiration date, and people have voted, schedule a notification

    return unless poll.present? && poll.expires_at.present? && poll.votes.exists?

    PollExpirationNotifyWorker.remove_from_scheduled(poll.id) if @previous_expires_at.present? && @previous_expires_at > poll.expires_at
    PollExpirationNotifyWorker.perform_at(poll.expires_at + 5.minutes, poll.id)
  end

  def create_previous_edit!
    # We only need to create a previous edit when no previous edits exist, e.g.
    # when the status has never been edited. For other cases, we always create
    # an edit, so the step can be skipped

    return if @status.edits.any?

    @status.snapshot!(
      media_attachments_changed: false,
      at_time: @status.created_at
    )
  end

  def create_edit!
    @status.snapshot!(
      media_attachments_changed: @media_attachments_changed || @poll_changed,
      account_id: @account_id
    )
  end
end
