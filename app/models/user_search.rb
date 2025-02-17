# frozen_string_literal: true

# Searches for a user by username or full text or name (if enabled in SiteSettings)
require_dependency 'search'

class UserSearch

  def initialize(term, opts = {})
    @term = term
    @term_like = "#{term.downcase.gsub("_", "\\_")}%"
    @topic_id = opts[:topic_id]
    @category_id = opts[:category_id]
    @topic_allowed_users = opts[:topic_allowed_users]
    @searching_user = opts[:searching_user]
    @include_staged_users = opts[:include_staged_users] || false
    @limit = opts[:limit] || 20
    @groups = opts[:groups]
    @guardian = Guardian.new(@searching_user)
    @guardian.ensure_can_see_groups!(@groups) if @groups
  end

  def scoped_users
    users = User.where(active: true)
    users = users.where(staged: false) unless @include_staged_users

    if @groups
      users = users.joins("INNER JOIN group_users ON group_users.user_id = users.id")
        .where("group_users.group_id IN (?)", @groups.map(&:id))
    end

    unless @searching_user && @searching_user.staff?
      users = users.not_suspended
    end

    # Only show users who have access to private topic
    if @topic_id && @topic_allowed_users == "true"
      topic = Topic.find_by(id: @topic_id)

      if topic.category && topic.category.read_restricted
        users = users.includes(:secure_categories)
          .where("users.admin = TRUE OR categories.id = ?", topic.category.id)
          .references(:categories)
      end
    end

    users.limit(@limit)
  end

  def filtered_by_term_users
    users = scoped_users

    if @term.present?
      if SiteSetting.enable_names? && @term !~ /[_\.-]/
        query = Search.ts_query(term: @term, ts_config: "simple")

        users = users.includes(:user_search_data)
          .references(:user_search_data)
          .where("user_search_data.search_data @@ #{query}")
          .order(DB.sql_fragment("CASE WHEN username_lower LIKE ? THEN 0 ELSE 1 END ASC", @term_like))

      else
        users = users.where("username_lower LIKE :term_like", term_like: @term_like)
      end
    end

    users
  end

  def search_ids
    users = Set.new

    # 1. exact username matches
    if @term.present?
      scoped_users.where(username_lower: @term.downcase)
        .limit(@limit)
        .pluck(:id)
        .each { |id| users << id }

    end

    return users.to_a if users.length >= @limit

    # 2. in topic
    if @topic_id
      in_topic = filtered_by_term_users
        .where('users.id IN (SELECT p.user_id FROM posts p WHERE topic_id = ?)', @topic_id)

      if @searching_user.present?
        in_topic = in_topic.where('users.id <> ?', @searching_user.id)
      end

      in_topic
        .order('last_seen_at DESC')
        .limit(@limit - users.length)
        .pluck(:id)
        .each { |id| users << id }
    end

    return users.to_a if users.length >= @limit

    secure_category_id = nil

    if @category_id
      secure_category_id = DB.query_single(<<~SQL, @category_id).first
        SELECT id FROM categories
        WHERE read_restricted AND id = ?
      SQL
    elsif @topic_id
      secure_category_id = DB.query_single(<<~SQL, @topic_id).first
        SELECT id FROM categories
        WHERE read_restricted AND id IN (
          SELECT category_id FROM topics
          WHERE id = ?
        )
      SQL
    end

    # 3. category matches
    # 10,11,12: trust level groups (tl0/1/2) explicitly bypassed
    # may amend this in future to allow them if count in the group
    # is small enough
    if secure_category_id
      in_category = filtered_by_term_users
        .where(<<~SQL, secure_category_id)
          users.id IN (
            SELECT gu.user_id
            FROM group_users gu
            WHERE group_id IN (
              SELECT group_id FROM category_groups
              WHERE category_id = ?
            ) AND group_id NOT IN (10,11,12)
            LIMIT 200
          )
          SQL

      if @searching_user.present?
        in_category = in_category.where('users.id <> ?', @searching_user.id)
      end

      in_category
        .order('last_seen_at DESC')
        .limit(@limit - users.length)
        .pluck(:id)
        .each { |id| users << id }
    end

    return users.to_a if users.length >= @limit
    # 4. global matches
    if @term.present?
      filtered_by_term_users.order('last_seen_at DESC')
        .limit(@limit - users.length)
        .pluck(:id)
        .each { |id| users << id }
    end

    users.to_a
  end

  def search
    ids = search_ids
    return User.where("0=1") if ids.empty?

    User.joins("JOIN (SELECT unnest uid, row_number() OVER () AS rn
      FROM unnest('{#{ids.join(",")}}'::int[])
    ) x on uid = users.id")
      .order("rn")
  end

end
