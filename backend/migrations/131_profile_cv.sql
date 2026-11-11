-- A saved CV on the person's Work profile (PDF in uploads/cv/). Private:
-- only its owner and verified HRs can open it (ApplicationsController.serveCV).
ALTER TABLE users ADD COLUMN IF NOT EXISTS cv_path VARCHAR(300);
