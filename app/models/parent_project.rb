# Parent project used for index and query issues, news, projects and etc with parent.
class ParentProject < Project
  index_name RedmineElasticsearch::INDEX_NAME

  class << self

    # Import all projects to 'parent_project' document type.
    # 'parent_project' is a project tree for all other items.
    def import(options={}, &block)
      # Batch size for bulk operations
      batch_size = options.fetch(:batch_size, RedmineElasticsearch::BATCH_SIZE_FOR_IMPORT)

      # Imported records counter
      imported   = 0

      # Errors counter
      errors     = 0

      find_in_batches(batch_size: batch_size) do |items|
        response = __elasticsearch__.client.bulk(
          index: index_name,
          type:  document_type,
          body:  items.map do |item|
            data = item.to_indexed_json
            { index: { _id: item.id, data: data } }
          end
        )
        imported += items.length
        errors   += response['items'].map { |k, v| k.values.first['error'] }.compact.length

        # Call block with imported records count in batch
        yield(imported) if block_given?
      end
      errors
    end

    def searching_scope
      self.where(nil)
    end

    def allowed_to_search_query(user, options = {})
      permission = options[:permission] || :search_project
      perm       = Redmine::AccessControl.permission(permission)

      must_queries = []

      # If the permission belongs to a project module, make sure the module is enabled
      if perm && perm.project_module
        must_queries << {
					terms: { project_id: Project.joins(:enabled_modules).where('enabled_modules.name': perm.project_module).map(&:id) }
        }
      end

      must_queries << { term: { type: options[:type] } } if options[:type].present?

      unless user.admin?
        statement_by_role    = {}
        role                 = user.logged? ? Role.non_member : Role.anonymous
        hide_public_projects = user.pref[:hide_public_projects] == '1'
        if role.allowed_to?(permission) && !hide_public_projects
          statement_by_role[role] = {
						terms: { project_id: Project.where(is_public: true).map(&:id) }
          }
        end
        if user.logged?
          user.projects_by_role.each do |role, projects|
            if role.allowed_to?(permission) && projects.any?
              statement_by_role[role] = {
								terms: { project_id: projects.collect(&:id) }
              }
            end
          end
        end
        if statement_by_role.empty?
          must_queries = [{ term: { id: { value: 0 } } }]
        else
          if block_given?
            statement_by_role.each do |role, statement|
              block_statement = yield(role, user)
              if block_statement.present?
                statement_by_role[role] = {
                  bool: {
                    must: [statement, block_statement]
                  }
                }
              end
            end
          end
          must_queries << { bool: { should: statement_by_role.values, minimum_should_match: 1 } }
        end
      end
      {
        bool: {
          must: must_queries
        }
      }
    end

  end

end
