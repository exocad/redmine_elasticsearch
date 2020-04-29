class ParentProjectSerializer < ActiveModel::Serializer
  attributes :id,
             :is_public,
             :status_id,
						 :enabled_module_names,
						 :relation

  def status_id
    object.status
	end
	
	def relation
		'parent_project'
	end
end
