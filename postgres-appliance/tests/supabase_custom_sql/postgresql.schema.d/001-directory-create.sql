CREATE TABLE IF NOT EXISTS public.supabase_custom_hook_log (
    hook_name text PRIMARY KEY,
    applied_as text NOT NULL,
    applied_at timestamp with time zone NOT NULL DEFAULT now()
);

INSERT INTO public.supabase_custom_hook_log (hook_name, applied_as)
VALUES ('001-directory-create', current_user)
ON CONFLICT (hook_name) DO UPDATE
SET applied_as = EXCLUDED.applied_as;