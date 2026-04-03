CREATE TABLE IF NOT EXISTS public.supabase_custom_hook_log (
    hook_name text PRIMARY KEY,
    applied_as text NOT NULL,
    applied_session_user text,
    applied_at timestamp with time zone NOT NULL DEFAULT now()
);

ALTER TABLE public.supabase_custom_hook_log
    ADD COLUMN IF NOT EXISTS applied_session_user text;

INSERT INTO public.supabase_custom_hook_log (hook_name, applied_as, applied_session_user)
VALUES ('001-directory-create', current_user, session_user)
ON CONFLICT (hook_name) DO UPDATE
SET applied_as = EXCLUDED.applied_as,
    applied_session_user = EXCLUDED.applied_session_user;