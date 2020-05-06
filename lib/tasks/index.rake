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

    puts 'Recreating index and updating mapping...'
    RedmineElasticsearch::IndexerService.recreate_index

    puts "Available search types: [#{Redmine::Search.available_search_types.join(', ')}]"

    # Errors counter
    errors = 0

		# (Re-)Create attachments-ingest-pipline
    RedmineElasticsearch::IndexerService.recreate_attachments_ingest

    # Reindex all searchable types
    Redmine::Search.available_search_types.each do |search_type|
      reindex_document_type search_type
    end

    puts 'Refresh index for allowing searching right after reindex...'
    RedmineElasticsearch.client.indices.refresh

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

  task :logged => :environment do
    logger                    = Logger.new(STDOUT)
    logger.level              = Logger::WARN
    ActiveRecord::Base.logger = logger
  end

	def batch_size
		if ENV['BATCH_SIZE'].present?
			ENV['BATCH_SIZE'].to_i
		else
			16
		end
  end

  def reindex_document_type(search_type)
    puts "\nCounting estimated records for #{search_type}..."
    estimated_records = RedmineElasticsearch::IndexerService.count_estimated_records(search_type)
    puts "#{estimated_records} will be imported."
    bar = ANSI::ProgressBar.new("#{search_type}", estimated_records)
    bar.flush
    errors = RedmineElasticsearch::IndexerService.reindex(search_type, batch_size: batch_size) do |imported_records|
      bar.set imported_records
    end
    bar.halt
    puts "Done reindex #{search_type}. Errors: #{errors}"
    errors
  end

end
