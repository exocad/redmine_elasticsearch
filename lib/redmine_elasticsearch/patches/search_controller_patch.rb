require_dependency 'search_controller'

module RedmineElasticsearch
  module Patches
    module SearchControllerPatch

      def index
        get_variables_from_params

        # quick jump to an issue
        if issue = detect_issue_in_question(@question)
          redirect_to issue_path(issue)
          return
        end

        # First searching with advanced query with parsing it on elasticsearch side.
        # If it fails then use match query.
        # http://www.elasticsearch.org/guide/en/elasticsearch/reference/current/query-dsl-match-query.html#_comparison_to_query_string_field
        # The match family of queries does not go through a "query parsing" process.
        # It does not support field name prefixes, wildcard characters, or other "advance" features.
        # For this reason, chances of it failing are very small / non existent,
        # and it provides an excellent behavior when it comes to just analyze and
        # run that text as a query behavior (which is usually what a text search box does).
        search_options = {
          scope:              @scope,
          q:                  @question,
          titles_only:        @titles_only,
          search_attachments: @search_attachments,
          all_words:          @all_words,
          page:               @page,
          size:               @limit,
          from:               @offset,
					projects:           @projects_to_search,

					issues_assigned:    @issues_assigned,
					issues_involved:    @issues_involved,
					issues_involved_or_watched: @issues_involved_or_watched,
					issues_created:    @issues_created
        }
        begin
          search_options[:search_type] = :query_string
          @results                     = perform_search(search_options)
        rescue => e
          logger.debug e
          search_options[:search_type] = :match
          @results                     = perform_search(search_options)
        end
        @search_type          = search_options[:search_type]
        @result_count         = @results.total
        @result_count_by_type = get_results_by_type_from_search_results(@results)

        @result_pages = Redmine::Pagination::Paginator.new @result_count, @limit, @page
        @offset       ||= @result_pages.offset

        respond_to do |format|
          format.html { render :layout => false if request.xhr? }
          format.api { @results ||= []; render :layout => false }
        end
      rescue Faraday::ConnectionFailed, Errno::ECONNREFUSED => e
        logger.error e
        render_error message: :search_connection_refused, status: 503
      rescue => e
        logger.error e
        render_error message: :search_request_failed, status: 503
      end

      private

      def get_variables_from_params
        @question = params[:q] || ''
        @question.strip!
        @all_words          = params[:all_words] ? params[:all_words].present? : true
        @titles_only        = params[:titles_only] ? params[:titles_only].present? : false
        @projects_to_search = get_projects_from_params
        @object_types       = allowed_object_types(@projects_to_search)
        @scope              = filter_object_types_from_params(@object_types)
        @search_attachments = params[:attachments].presence || '0'
				@open_issues        = params[:open_issues] ? params[:open_issues].present? : false
				
				@issues_assigned = params[:issues_assigned] ? params[:issues_assigned].present? : false
				@issues_involved = params[:issues_involved] ? params[:issues_involved].present? : false
				@issues_created = params[:issues_created] ? params[:issues_created].present? : false
				@issues_involved_or_watched = params[:issues_involved_or_watched] ? params[:issues_involved_or_watched].present? : false

        @page = [params[:page].to_i, 1].max
        case params[:format]
          when 'xml', 'json'
            @offset, @limit = api_offset_and_limit
          else
            @limit  = Setting.search_results_per_page.to_i
            @limit  = 10 if @limit == 0
            @offset = (@page - 1) * @limit
        end

        # extract tokens from the question
        # eg. hello "bye bye" => ["hello", "bye bye"]
        @tokens = @question.scan(%r{((\s|^)"[\s\w]+"(\s|$)|\S+)}).collect { |m| m.first.gsub(%r{(^\s*"\s*|\s*"\s*$)}, '') }
        # tokens must be at least 2 characters long
        @tokens = @tokens.uniq.select { |w| w.length > 1 }
      end

      def detect_issue_in_question(question)
        (m = question.match(/^#?(\d+)$/)) && Issue.visible.find_by_id(m[1].to_i)
      end

      def get_projects_from_params
        case params[:scope]
          when 'all'
            nil
          when 'my_projects'
            User.current.projects
          when 'subprojects'
            @project ? (@project.self_and_descendants.active.all) : nil
          else
            @project
        end
      end

      def allowed_object_types(projects_to_search)
        object_types = Redmine::Search.available_search_types.dup
        if projects_to_search.is_a? Project
          # don't search projects
          object_types.delete('projects')
          # only show what the user is allowed to view
          object_types = object_types.select { |o| User.current.allowed_to?("view_#{o}".to_sym, projects_to_search) }
        end
        object_types
      end

      def filter_object_types_from_params(object_types)
        scope = object_types.select { |t| params[t] }
        scope = object_types if scope.empty?
        scope
      end

      def perform_search(options = {})
        #todo: refactor this
        project_ids = options[:projects] ? [options[:projects]].flatten.compact.map(&:id) : Project.where("status <> #{Project::STATUS_ARCHIVED}").map(&:id)

        search_fields   = get_search_fields(
          titles_only: options[:titles_only],
          search_attachments: options[:search_attachments]
        )
        search_operator = options[:all_words] ? 'AND' : 'OR'
        main_query = get_main_query(options, search_fields, search_operator)

        document_types = options[:scope].map(&:singularize)
        common_must = [{ terms: { type: document_types } }]

        if project_ids
          common_must << {
						terms: { project_id: project_ids }
          }
        end

        common_must_not = []

        # Search only open issues if such option is selected
        common_must_not << { term: { closed: { value: true } } } if @open_issues

        common_should = []

        document_types.each do |search_type|
          search_klass = RedmineElasticsearch.type2class(search_type)
          type_query   = search_klass.allowed_to_search_query(User.current)
          common_should << type_query if type_query
				end
				
				userid = User.current.id
				userorgroupid = [userid] + User.current.groups.map(&:id)

				common_must << { term: { author_id: userid } } if options[:issues_created]
				common_must << { terms: { assigned_to_id: userorgroupid } } if options[:issues_assigned]
				common_must << { bool: { should:
					[
						{ terms: { assigned_to_id: userorgroupid } },
						{ term: { author_id: userid } },
						{ term: { 'journals.user_id': userid } }
					],
          minimum_should_match: 1
				} } if options[:issues_involved]
				common_must << { bool: { should:
					[
						{ terms: { assigned_to_id: userorgroupid } },
						{ terms: { watchers: userorgroupid } },
						{ term: { author_id: userid } },
						{ term: { 'journals.user_id': userid } }
					],
          minimum_should_match: 1
				} } if options[:issues_involved_or_watched]

        payload = {
          query: {
            bool: {
              must: main_query,
							
							filter: [{
								bool: {
									must: common_must,
									must_not: common_must_not,
									should: common_should,
									minimum_should_match: 1
								}
							}]
            }
          },
          sort:  [
                   { datetime: { order: 'desc' } },
                   :_score
                 ],
          aggs:  {
            event_types: {
              terms: {
                field: 'type'
              }
            }
          }
        }

        search_options = {
          size: options[:size],
          from: options[:from]
        }.merge payload

        search      = Elasticsearch::Model.search search_options, [], index: RedmineElasticsearch::INDEX_NAME, type: '_doc'
        @query_curl ||= []
        search.results
      end

      # Get list of searchable fields regardles of searching options: 'titles_only', 'search_attachments'
      def get_search_fields(titles_only:, search_attachments:)
        search_fields = titles_only ?
          %w(title) :
          %w(title description journals.notes custom_field_values)

        search_attachment_fields = titles_only ?
          %w(attachments.title) :
          %w(attachments.title attachments.file attachments.filename attachments.description)

        case search_attachments
          when '1'
            search_fields + search_attachment_fields
          when 'only'
            search_attachment_fields
          else
            search_fields
        end
      end

      def get_main_query(options, search_fields, search_operator)
        case options[:search_type]
          when :query_string
            {
              query_string: {
                query:            options[:q],
                default_operator: search_operator,
                fields:           search_fields
              }
            }
          when :match
            {
              multi_match: {
                query:       options[:q],
                operator:    search_operator,
                fields:      search_fields
              }
            }
          else
            raise "Unknown search_type: #{options[:search_type].inspect}"
        end
      end

      def get_results_by_type_from_search_results(results)
        results_by_type = Hash.new { |h, k| h[k] = 0 }
        unless results.empty?
          results.response.aggregations.event_types.buckets.each do |facet|
            results_by_type[facet['key']] = facet['doc_count']
          end
        end
        results_by_type
      end
    end
  end
end
