class JournalSerializer < ActiveModel::Serializer
  self.root = false

  attributes :id, :notes, :user_id
end
