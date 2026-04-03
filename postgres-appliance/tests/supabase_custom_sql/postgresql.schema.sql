INSERT INTO public.supabase_custom_hook_log (hook_name, applied_as, applied_session_user)
VALUES ('999-post-migration-file', current_user, session_user)
ON CONFLICT (hook_name) DO UPDATE
SET applied_as = EXCLUDED.applied_as,
	applied_session_user = EXCLUDED.applied_session_user;