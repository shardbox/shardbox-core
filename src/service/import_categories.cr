struct Service::ImportCategories
  def initialize(@db : ShardsDB, @catalog : Catalog)
  end

  def perform
    category_stats = update_categories

    update_categorizations
    delete_obsolete_categorizations

    category_stats
  end

  def update_categories
    all_categories = @db.connection.query_all <<-SQL, @catalog.categories.keys, as: {String?, String?, String?, String?}
      SELECT
        categories.slug::text, target_categories.slug, name::text, description
      FROM
        categories
      FULL OUTER JOIN
        (
          SELECT unnest($1::text[]) AS slug
        ) AS target_categories
        ON categories.slug = target_categories.slug
      SQL

    deleted_categories = [] of String
    new_categories = [] of String
    updated_categories = [] of String
    all_categories.each do |existing_slug, new_slug, name, description|
      if existing_slug.nil?
        category = @catalog.categories[new_slug]
        @db.create_category(category)
        new_categories << new_slug.not_nil!
      elsif new_slug.nil?
        @db.remove_category(existing_slug.not_nil!)
        deleted_categories << existing_slug.not_nil!
      else
        category = @catalog.categories[existing_slug]
        if category.name != name || category.description != description
          @db.update_category(category)
          updated_categories << category.slug
        end
      end
    end

    {
      "deleted_categories" => deleted_categories,
      "new_categories"     => new_categories,
      "updated_categories" => updated_categories,
    }
  end

  def update_categorizations
    @catalog.entries.each do |entry|
      @db.update_categorization(entry.repo_ref, entry.categories)
    end
  end

  def delete_obsolete_categorizations
    @db.delete_categorizations(@catalog.entries.map &.repo_ref)
  end
end
