module ContactSearch
  extend ActiveSupport::Concern

  module ClassMethods

    def allowed_to_search_query(user, options = {})
      options = options.merge(
        permission: :view_contacts,
        type:       'contact'
      )
      ParentProject.allowed_to_search_query(user, options)
    end

  end
end
