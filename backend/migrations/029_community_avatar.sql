-- Communities previously only had a fixed icon_emoji + cover_color. Let a
-- community upload a real avatar image, same as users/group chats already can
-- (mirrors conversations.avatar_url, added in 015_group_conversations.sql).
ALTER TABLE communities ADD COLUMN avatar_url TEXT;
