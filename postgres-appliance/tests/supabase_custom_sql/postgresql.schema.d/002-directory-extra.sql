INSERT INTO public.supabase_custom_hook_log (hook_name, applied_as)
VALUES ('002-directory-extra', current_user)
ON CONFLICT (hook_name) DO UPDATE
SET applied_as = EXCLUDED.applied_as;