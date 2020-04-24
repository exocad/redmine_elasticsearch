class JournalSerializer < ActiveModel::Serializer
  attributes :id, :notes, :user_id
end
