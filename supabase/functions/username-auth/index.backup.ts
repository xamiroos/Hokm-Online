import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.57.0'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...cors, 'Content-Type': 'application/json' },
})
const validUsername = (u: string) => /^[a-z0-9_]{3,24}$/.test(u)

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return reply({ error: 'Method not allowed' }, 405)
  const url = Deno.env.get('SUPABASE_URL')!
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
  let body: { action?: string; username?: string; password?: string }
  try { body = await req.json() } catch { return reply({ error: 'درخواست نامعتبر است.' }, 400) }
  const username = String(body.username ?? '').trim().toLowerCase()
  const password = String(body.password ?? '')
  if (!validUsername(username)) return reply({ error: 'نام کاربری باید ۳ تا ۲۴ نویسه و شامل حروف انگلیسی، عدد یا زیرخط باشد.' }, 400)
  if (password.length < 8 || password.length > 72) return reply({ error: 'رمز عبور باید بین ۸ تا ۷۲ نویسه باشد.' }, 400)
  // Internal synthetic address: it is never used for email delivery and is not shown in the UI.
  const email = `${username}@users.hokm.invalid`

  if (body.action === 'signup') {
    const { data: existing } = await admin.from('player_profiles').select('id').eq('username', username).maybeSingle()
    if (existing) return reply({ error: 'این نام کاربری قبلاً گرفته شده است.' }, 409)
    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email, password, email_confirm: true, user_metadata: { username },
    })
    if (createError || !created.user) return reply({ error: 'ساخت حساب انجام نشد؛ ممکن است نام کاربری تکراری باشد.' }, 400)
    const { error: profileError } = await admin.from('player_profiles').insert({ id: created.user.id, username, display_name: username })
    if (profileError) {
      await admin.auth.admin.deleteUser(created.user.id)
      return reply({ error: 'این نام کاربری در حال حاضر قابل استفاده نیست؛ نام دیگری انتخاب کن.' }, 409)
    }
  } else if (body.action !== 'login') {
    return reply({ error: 'عملیات نامعتبر است.' }, 400)
  }

  // Sign in through the public Auth API; service-role key is used only inside this Edge Function.
  const publicClient = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data, error } = await publicClient.auth.signInWithPassword({ email, password })
  if (error || !data.session) return reply({ error: body.action === 'signup' ? 'حساب ساخته شد، اما ورود خودکار انجام نشد؛ دوباره وارد شو.' : 'نام کاربری یا رمز عبور درست نیست.' }, 401)
  return reply({ access_token: data.session.access_token, refresh_token: data.session.refresh_token, expires_at: data.session.expires_at })
})
