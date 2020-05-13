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

			# objects too large, try split-handling
			too_large_objects = []

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

				too_large_objects += ApplicationSearch.adaptive_batch(chunk) do |sub_chunk|
					response = __elasticsearch__.client.bulk(index: index_name, body: sub_chunk, pipeline: pipeline)
					imported += sub_chunk.length
					errors   += response['items'].map { |k, v| k.values.first['error'] }.compact.length

        # Call block with imported records count in batch
        yield(imported) if block_given?
			end
			
			puts "Too large for transfer: #{too_large_objectes.map(&:id).join(', ')}"

      errors + too_large_objects.size
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

	# Andaptively tries to progress the given batch and increases/decreases the batch size
	# in order to transfer the whole batch and handle too large entity sizes.
	def self.adaptive_batch(batch, &block)
		s0 = 0
		step = batch.size
		too_large_objects = []
		while s0 < batch.size
			begin
				yield(batch[s0, step])
				s0 += step
				step = (step * 1.5).ceil if step < batch.size # slightly increase step size
			rescue Elasticsearch::Transport::Transport::Errors::RequestEntityTooLarge
				if(step == 1)
					too_large_objects << batch[0]
					step = batch.size # it is likely that this object did cause the overall problem, so proceed normally
					s0 += 1 # skip problematic element for now
				else
					step = (step/2.0).floor
				end
			end
		end
		too_large_objects
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
