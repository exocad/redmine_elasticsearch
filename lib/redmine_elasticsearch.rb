require 'elasticsearch'
require 'elasticsearch/model'

module RedmineElasticsearch
	INDEX_NAME            = "#{Rails.application.class.parent_name.downcase}_#{Rails.env}"
	ATTACHMENTS_PIPELINE  = "#{Rails.application.class.parent_name.downcase}_attachments"
  BATCH_SIZE_FOR_IMPORT = 300

	STATE_FILE = Rails.root.join('tmp', 'es_index_state')
	TS_FILE = Rails.root.join('tmp', 'es_index_timestamp')
	BATCH_INFO_FILE = Rails.root.join('tmp', 'es_index_batch_log')

  def type2class_name(type)
    type.to_s.underscore.classify
  end

  def type2class(type)
    self.type2class_name(type).constantize
  end

  def search_klasses
    Redmine::Search.available_search_types.map { |type| type2class(type) }
  end

	def file_read(file, &block)
		return false unless File.exists? file
		
		begin
			file = File.open(file, 'r')
			ret = file.read
			file.close
		rescue => e
			return false
		end

		yield(ret) if block_given?
		return ret
	end

	def file_write(file, data = '')
		begin
			file = File.open(file, 'w')
			ret = file.write data
			file.close
		rescue
			return false
		end
		return true
	end

  def apply_patch(patch, *targets)
    targets = Array(targets).flatten
    targets.each do |target|
      unless target.included_modules.include? patch
        target.send :prepend, patch
      end
    end
  end

  def additional_index_properties(document_type)
    @additional_index_properties                = {}
    @additional_index_properties[document_type] ||= begin
      Rails.configuration.respond_to?(:additional_index_properties) ?
        Rails.configuration.additional_index_properties.fetch(document_type, {}) : {}
    end
  end

  def client(cache: true)
    if cache
      @client ||= Elasticsearch::Client.new client_options
    else
      @client = Elasticsearch::Client.new client_options
    end
  end

  def client_options
    @client_options ||=
      (Redmine::Configuration['elasticsearch'] || { request_timeout: 180 }).symbolize_keys
  end

  # Refresh the index and to make the changes (creates, updates, deletes) searchable.
  def refresh_indices
    client.indices.refresh
  end

  extend self
end

%w{elastic serializers}.each do |fold|
  fold_path                                  = File.dirname(__FILE__) + "/../app/#{fold}"
  ActiveSupport::Dependencies.autoload_paths += [fold_path]
end

require_dependency 'redmine_elasticsearch/patches/redmine_search_patch'
require_dependency 'redmine_elasticsearch/patches/search_controller_patch'
require_dependency 'redmine_elasticsearch/patches/issue_patch'

ActiveSupport::Reloader.to_prepare do
  RedmineElasticsearch.apply_patch RedmineElasticsearch::Patches::RedmineSearchPatch, Redmine::Search
  RedmineElasticsearch.apply_patch RedmineElasticsearch::Patches::SearchControllerPatch, SearchController
  RedmineElasticsearch.apply_patch RedmineElasticsearch::Patches::ResponseResultsPatch, Elasticsearch::Model::Response::Results
  RedmineElasticsearch.apply_patch RedmineElasticsearch::Patches::IssuePatch, Issue

  # Using plugin's configured client in all models
  Elasticsearch::Model.client = RedmineElasticsearch.client
end
