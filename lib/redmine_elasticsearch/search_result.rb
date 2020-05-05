module RedmineElasticsearch
  class SearchResult < Elasticsearch::Model::Response::Result

		@@event_url_base = "#{Setting.protocol}://#{Setting.host_name}".sub(/^\/+$/, '') + '/'

    def project
      @project ||= Project.find_by_id(project_id)
		end
		
		def type
			@result['_source']['type']
		end
		def id
			@result['_source']['id']
		end
		def url
			rel = @result['_source']['url']
			URI.join(@@event_url_base, rel ? rel.sub(/^\/+/, '') : '').to_s
		end

    # Adding event attributes aliases
    %w(datetime title description author type url).each do |attr|
      src = <<-END_SRC
            def event_#{attr}(*args)   
              #{attr}
            end
      END_SRC
      class_eval src, __FILE__, __LINE__
    end

  end
end