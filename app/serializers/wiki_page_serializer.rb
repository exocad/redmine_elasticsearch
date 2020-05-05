class WikiPageSerializer < BaseSerializer
  attributes :project_id,
             :title, :text,
             :created_on, :updated_on

  has_many :attachments, serializer: AttachmentSerializer

  def project_id
    object.wiki.try(:project_id)
  end

  def author
    nil
	end
	
  def default_url_options
    super.merge({ project_id: object.wiki.try(:project_id) })
  end
end
