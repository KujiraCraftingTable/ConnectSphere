-- 137, "Check legit" is now called "Reviews". Sellers' posts still holding the
-- old default text get the new one; posts the seller rewrote are left alone.
-- The old translation was made from the old text, so it goes too.
UPDATE posts
SET content = E'✅ Reviews\nReviews from people who bought from me. Each one comes from a buyer I sent a review card to after our deal.',
    translated_text = NULL,
    translated_hash = NULL
WHERE post_type = 'legit'
  AND content = E'✅ Check legit\nReviews from people who bought from me. Each one comes from a buyer I sent a legit card to after our deal.';
