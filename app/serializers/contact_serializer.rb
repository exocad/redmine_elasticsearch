class ContactSerializer < BaseSerializer
  def project_id
    object.project_ids
  end
end
