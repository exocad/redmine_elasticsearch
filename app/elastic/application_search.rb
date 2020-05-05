module ApplicationSearch
  extend ActiveSupport::Concern

  included do
		include Elasticsearch::Model
		
		document_type self.model_name.element

    # Import all records to elastic
    # @return [Integer] errors count
    def self.import(options = {}, &block)
      # Batch size for bulk operations
			batch_size = options.fetch(:batch_size, RedmineElasticsearch::BATCH_SIZE_FOR_IMPORT)

			# Pipeline for analyzing file attachments
			pipeline = RedmineElasticsearch::ATTACHMENTS_PIPELINE

      # Document type
      type = options.fetch(:type, document_type)

      # Imported records counter
      imported = 0

      # Errors counter
      errors = 0

			find_in_batches(batch_size: batch_size) do |items|
				chunk = []
				items.each do |item|
					data   = item.to_indexed_json
					if data[:url].nil?
						errors.inc
					else 
						chunk.push({ index: { _id: "#{type}#{item.id}", data: data } })
					end
				end

        response = __elasticsearch__.client.bulk(index: index_name, body: chunk, pipeline: pipeline)
        imported += items.length
        errors   += response['items'].map { |k, v| k.values.first['error'] }.compact.length

        # Call block with imported records count in batch
        yield(imported) if block_given?
      end
      errors
		end
		
    index_name RedmineElasticsearch::INDEX_NAME

    after_commit :async_update_index
  end

  def to_indexed_json
    RedmineElasticsearch::SerializerService.serialize_to_json(self)
  end

  def async_update_index
    Workers::Indexer.defer(self)
  end

  module ClassMethods

    def index_mapping
      {
      }
    end

    def additional_index_mappings
      return {} unless Rails.configuration.respond_to?(:additional_index_properties)
      Rails.configuration.additional_index_properties[self.name.tableize.to_sym] || {}
    end

    # Update mapping for document type
    def update_mapping
      __elasticsearch__.client.indices.put_mapping(
        index: index_name,
        body:  index_mapping
      )
    end

    def allowed_to_search_query(user, options = {})
      options = options.merge(
        permission: :view_project,
        type:       document_type
      )
      ParentProject.allowed_to_search_query(user, options)
    end

    def searching_scope(project_id)
      self.where('project_id = ?', project_id)
    end


    def remove_from_index(id)
      __elasticsearch__.client.delete index: index_name, id: id
    end
  end

  def update_index
    self.class.where(id: self.id).import
  end
end
