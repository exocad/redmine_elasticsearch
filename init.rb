require 'redmine'

Redmine::Plugin.register :redmine_elasticsearch do
  name        'Redmine Elasticsearch Plugin'
  description 'This plugin integrates the Elasticsearch full-text search engine into Redmine.'
  author      'Restream'
  version     '0.2.1'
  url         'https://github.com/Restream/redmine_elasticsearch'

  requires_redmine version_or_higher: '4.0'
end

require 'redmine_elasticsearch'
