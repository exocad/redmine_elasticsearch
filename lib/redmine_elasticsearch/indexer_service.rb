module RedmineElasticsearch

  class IndexerError < StandardError
  end

  class IndexerService

    class << self
      def recreate_index
        delete_index if index_exists?
        create_index
        update_mapping
        RedmineElasticsearch.refresh_indices
      end

      # Recreate index and mapping and then import documents
      # @return [Integer] errors count
      #
      def reindex_all(options = {}, &block)

        # Errors counter
        errors = 0

        # Delete and create indexes
        recreate_index

        # Importing parent project first
        ParentProject.import

        # Import records from all searchable classes
        RedmineElasticsearch.search_klasses.each do |search_klass|
          errors += search_klass.import options, &block
        end

        # Refresh index for allowing searching right after reindex
        RedmineElasticsearch.client.indices.refresh

        errors
      end

      # Reindex only given search type
      def reindex(search_type, options = {}, &block)
        search_klass = find_search_klass(search_type)
        create_index unless index_exists?
        search_klass.update_mapping

        # Import records from given searchable class
        errors = search_klass.import options do |imported_records|
          yield(imported_records) if block_given?
        end

        errors
      end

      def count_estimated_records(search_type = nil)
        search_klass = search_type && find_search_klass(search_type)
        search_klass ?
          search_klass.count :
          RedmineElasticsearch.search_klasses.inject(0) { |sum, klass| sum + klass.count }
      end

      protected

      def logger
        ActiveRecord::Base.logger
      end

      def update_mapping
        RedmineElasticsearch.search_klasses.each { |search_klass| search_klass.update_mapping }
      end

      def index_exists?
        RedmineElasticsearch.client.indices.exists? index: RedmineElasticsearch::INDEX_NAME
      end

      def create_index
        RedmineElasticsearch.client.indices.create(
          index: RedmineElasticsearch::INDEX_NAME,
          body:  {
            settings: {
              index:    {
                number_of_shards:   1,
                number_of_replicas: 0
              },
              analysis: {
                analyzer: {
                  default:        {
                    type:      'custom',
                    tokenizer: 'standard',
										filter:    %w(lowercase stoplist asciifolding hunspell_EN hunspell_DE)
                  }
                },
                filter:   {
									stoplist: {
										type: "stop",
										stopwords: ["_english_", "_german_"]
									},
									hunspell_DE: {
										"type": "hunspell",
										"locale": "de_DE",
										"dedup": true
									},
									hunspell_EN: {
										"type": "hunspell",
										"locale": "en_US",
										"dedup": true
									}
                }
              }
            },
            mappings: {
              # _default_: {
              #   properties: {
              #     type:        { type: 'keyword' },
              #     title:       { type: 'text' },
              #     description: { type: 'text' },
              #     datetime:    { type: 'date' },
              #     url:         { type: 'text', index: 'not_analyzed' }
              #   }
							# }
							
							properties: {
								id:          { type: 'keyword' },
								project_id:  { type: 'keyword' },
								type:        { type: 'keyword' },
								watchers:    { type: 'keyword' },
								priority:    { type: 'keyword' },
								involved:    { type: 'keyword' },
								title:       { type: 'text' },
								description: { type: 'text' },
								datetime:    { type: 'date' },
								url:         { type: 'text', index: false },
								private:     { type: 'boolean' },
								is_private:  { type: 'alias', path: 'private' },
								closed:      { type: 'boolean' },
								is_closed:   { type: 'alias', path: 'closed' }
							}
            }
          }
        )
      end

      def delete_index
        RedmineElasticsearch.client.indices.delete index: RedmineElasticsearch::INDEX_NAME
      end

      def find_search_klass(search_type)
        validate_search_type(search_type)
        RedmineElasticsearch.type2class(search_type)
      end

      def validate_search_type(search_type)
        unless Redmine::Search.available_search_types.include?(search_type)
          raise IndexError.new("Wrong search type [#{search_type}]. Available search types are #{Redmine::Search.available_search_types}")
        end
      end
    end
  end
end
