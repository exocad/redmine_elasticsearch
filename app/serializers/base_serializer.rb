class BaseSerializer < ActiveModel::Serializer

  attributes :id, :project_id, :datetime, :title, :description, :author, :type, :url

  %w(datetime title description).each do |attr|
    class_eval "def #{attr}() object.event_#{attr} end"
	end

	def project_id
		object.project_id.to_s if object.respond_to? :project_id
	end
	
  def type
    object.class.document_type
  end

  def author
    object.event_author && object.event_author.to_s
  end

  def url
		Rails.application.routes.url_for object.event_url(default_url_options)
  rescue
    nil
  end

  def default_url_options
    { only_path: true }
  end
end
