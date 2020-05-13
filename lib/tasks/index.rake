require 'ansi/progressbar'

namespace :redmine_elasticsearch do

  desc 'Recreate index'
  task :recreate_index => :logged do
    puts 'Recreate index for all available search types'
    RedmineElasticsearch::IndexerService.recreate_index
    puts 'Done recreating index.'
  end

  desc 'Recreate index and reindex all available search types (BATCH_SIZE env variable is optional)'
  task :reindex_all => :logged do

		types = Redmine::Search.available_search_types
		start = 0
		skip_index_creation = false
		RedmineElasticsearch::file_read(RedmineElasticsearch::STATE_FILE) do |stat|
			if stat && stat =~ /^(\w+)\/(\d+)$/
				types = types[types.index($1.pluralize),types.size]
				start = $2.to_i
				skip_index_creation = true
			end
		end

		if skip_index_creation
			puts 'Recreating index and updating mapping...'
			RedmineElasticsearch::IndexerService.recreate_index

			# (Re-)Create attachments-ingest-pipline
			RedmineElasticsearch::IndexerService.recreate_attachments_ingest
			
			RedmineElasticsearch::IndexerService.recent_index_timestamp DateTime.now
		else
			puts 'Skipping re-creation of indices (continuing indexing)'
		end

    puts "Available search types: [#{types.join(', ')}]"

    # Errors counter
    errors = 0

    # Reindex all searchable types
    types.each do |search_type|
			errors += reindex_document_type search_type, start
			start = 0 # only first type should see start-index
    end

    puts 'Refresh index for allowing searching right after reindex...'
		RedmineElasticsearch.client.indices.refresh
		
		File.delete RedmineElasticsearch::STATE_FILE if File.exists? RedmineElasticsearch::STATE_FILE

    puts "Done reindex all. Errors: #{errors}"
  end

  desc 'Reindex search type (NAME env variable is required, BATCH_SIZE is optional)'
  task :reindex => :logged do
    search_type = ENV['NAME']
    raise 'Specify search type in NAME env variable' if search_type.blank?

    errors = 0

		# (Re-)Create attachments-ingest-pipline
		RedmineElasticsearch::IndexerService.recreate_attachments_ingest

    # Reindex document
    errors += reindex_document_type search_type

    puts 'Refresh index for allowing searching right after reindex...'
    RedmineElasticsearch.client.indices.refresh

    puts "Done. Errors: #{errors}"
  end

  
  desc 'Update the index using the update-timestamps in database (BATCH_SIZE is optional). This is more for testing purposes, as not all changes may update the timestamps.'
	task :update_index => :logged do
		
		if File.exists? RedmineElasticsearch::STATE_FILE
			abort 'Cannot update index as a reindexing appears not to be finished. Use redmine_elasticsearch:reindex_all to finish indexing first.'
		end

		ts = RedmineElasticsearch::IndexerService.recent_index_timestamp true
		unless ts.is_a? DateTime
			abort 'Cannot update index (no timestamp given). Use redmine_elasticsearch:reindex_all before updating.'
		end

    # Errors counter
		errors = 0
		
		puts 'Updating index incrementally...'
    # Update index on all searchable types
    Redmine::Search.available_search_types.each do |search_type|
    # ['wiki_pages'].each do |search_type|
      errors += reindex_document_type search_type
    end

    puts 'Refresh index for allowing searching right after reindex...'
		RedmineElasticsearch.client.indices.refresh
		
		RedmineElasticsearch::IndexerService.recent_index_timestamp DateTime.now

    puts "Done reindex all. Errors: #{errors}"
  end

  task :logged => :environment do
    logger                    = Logger.new(STDOUT)
    logger.level              = Logger::WARN
    ActiveRecord::Base.logger = logger
  end

	def batch_size
		if ENV['BATCH_SIZE'].present?
			ENV['BATCH_SIZE'].to_i
		else
			RedmineElasticsearch::BATCH_SIZE_FOR_IMPORT
		end
  end

  def reindex_document_type(search_type, start=0)
    puts "\nCounting estimated records for #{search_type}..."
		estimated_records = RedmineElasticsearch::IndexerService.count_estimated_records(search_type)
		if(estimated_records == 0)
			puts "Skipping - nothing to do."
			return 0
		end
    puts "#{estimated_records} will be imported."
    bar = ANSI::ProgressBar.new("#{search_type}", estimated_records)
    bar.flush
    errors = RedmineElasticsearch::IndexerService.reindex(search_type, batch_size: batch_size, start: start) do |imported_records|
      bar.set imported_records
    end
    bar.halt
    puts "Done reindex #{search_type}. Errors: #{errors}"
    errors
  end

end
