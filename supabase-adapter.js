(function(){
  const cfg=window.URBAN_TREND_SUPABASE;
  if(!cfg||!window.supabase){console.error('Supabase no está disponible');return}
  const client=window.supabase.createClient(cfg.url,cfg.anonKey);
  const keys={services:'ut_services_v3',products:'ut_products_v3',bookings:'ut_bookings_v3',cart:'ut_cart_v3',photos:'ut_photos_v3',config:'ut_config_v3'};
  let ready=false,session=null,syncing=false;
  const save=(key,value)=>localStorage.setItem(key,JSON.stringify(value));
  const publicImage=path=>client.storage.from('gallery').getPublicUrl(path).data.publicUrl;
  const serviceToLocal=x=>({id:x.id,name:x.name,duration:x.duration,price:Number(x.price)});
  const productToLocal=x=>({id:x.id,name:x.name,desc:x.description||'',tag:x.category||'General',price:Number(x.price),stock:Number(x.stock)});
  const bookingToLocal=x=>({id:x.id,name:x.customer_name,surname:x.customer_surname||'',phone:x.phone,service:x.service_name,date:x.booking_date,time:String(x.booking_time).slice(0,5),notes:x.notes||'',status:x.status,termsAcceptedAt:x.terms_accepted_at});
  const bookingToCloud=x=>({id:x.id,customer_name:x.name,customer_surname:x.surname||'',phone:x.phone||'',service_name:x.service,booking_date:x.date,booking_time:x.time,notes:x.notes||'',status:x.status||'Pendiente',terms_accepted_at:x.termsAcceptedAt||new Date().toISOString()});
  function rerender(){try{services=JSON.parse(localStorage.getItem(keys.services)||'[]');products=JSON.parse(localStorage.getItem(keys.products)||'[]')}catch{};try{renderServices();renderProducts();window.renderUrbanGallery?.();window.renderUrbanAdmin?.()}catch(error){console.error('No se pudo actualizar la vista',error)} }
  async function loadPublic(){
    const [s,p,g,c]=await Promise.all([client.from('services').select('*').eq('active',true).order('sort_order'),client.from('products').select('*').eq('active',true).order('name'),client.from('gallery').select('*').eq('active',true).order('sort_order'),client.from('business_settings').select('*').eq('id','main').maybeSingle()]);
    if(!s.error&&s.data?.length)save(keys.services,s.data.map(serviceToLocal));
    if(!p.error&&p.data?.length)save(keys.products,p.data.map(productToLocal));
    if(!g.error)save(keys.photos,(g.data||[]).map(x=>({id:x.id,title:x.title,data:publicImage(x.image_path),path:x.image_path})));
    if(!c.error&&c.data)save(keys.config,{name:c.data.name,whatsapp:c.data.whatsapp,phone:c.data.phone,email:c.data.email,address:c.data.address,hours:c.data.hours});
  }
  async function loadPrivate(){if(!session)return;const b=await client.from('bookings').select('*').order('booking_date').order('booking_time');if(!b.error)save(keys.bookings,(b.data||[]).map(bookingToLocal))}
  async function login(password){const {data,error}=await client.auth.signInWithPassword({email:cfg.adminEmail,password});if(error)return {ok:false,message:error.message||'No se pudo iniciar sesión'};session=data.session;await loadPrivate();rerender();return {ok:true}}
  async function logout(){await client.auth.signOut();session=null}
  async function replaceRows(table,rows){if(!session)return;const existing=await client.from(table).select('id'),ids=rows.map(x=>x.id);if(existing.data){const remove=existing.data.map(x=>x.id).filter(id=>!ids.includes(id));if(remove.length)await client.from(table).delete().in('id',remove)}if(rows.length){const result=await client.from(table).upsert(rows);if(result.error)throw result.error}}
  async function sync(key,value){if(!ready||syncing)return;syncing=true;try{
    if(key===keys.services)await replaceRows('services',value.map((x,i)=>({id:x.id,name:x.name,duration:x.duration,price:Number(x.price),active:true,sort_order:i})));
    if(key===keys.products)await replaceRows('products',value.map(x=>({id:x.id,name:x.name,description:x.desc||'',category:x.tag||'General',price:Number(x.price),stock:Number(x.stock),active:true})));
    if(key===keys.bookings){if(session)await replaceRows('bookings',value.map(bookingToCloud));else if(value.length){const row=bookingToCloud(value[value.length-1]);const result=await client.from('bookings').insert(row);if(result.error)throw result.error}}
    if(key===keys.config&&session){const x=value;await client.from('business_settings').upsert({id:'main',name:x.name,whatsapp:x.whatsapp,phone:x.phone,email:x.email,address:x.address,hours:x.hours,updated_at:new Date().toISOString()})}
    if(key===keys.photos&&session)await syncPhotos(value);
  }catch(error){console.error('No se pudo sincronizar',error);window.notify?.('Cambio guardado localmente; falta sincronizar')}finally{syncing=false}}
  async function dataUrlBlob(data){return(await fetch(data)).blob()}
  async function syncPhotos(photos){
    const cloud=await client.from('gallery').select('*'),keep=[];
    for(let i=0;i<photos.length;i++){const photo=photos[i];let path=photo.path;if(!path&&String(photo.data).startsWith('data:')){path=`trabajos/${photo.id}.jpg`;const upload=await client.storage.from('gallery').upload(path,await dataUrlBlob(photo.data),{contentType:'image/jpeg',upsert:true});if(upload.error)throw upload.error;photo.path=path;photo.data=publicImage(path)}keep.push({id:photo.id,title:photo.title,image_path:path,sort_order:i,active:true})}
    const remove=(cloud.data||[]).filter(x=>!keep.some(k=>k.id===x.id));if(remove.length){await client.storage.from('gallery').remove(remove.map(x=>x.image_path));await client.from('gallery').delete().in('id',remove.map(x=>x.id))}if(keep.length)await client.from('gallery').upsert(keep);save(keys.photos,photos)
  }
  async function init(){const auth=await client.auth.getSession();session=auth.data.session;if(session?.user?.email===cfg.adminEmail)sessionStorage.setItem('ut_admin_session','1');else sessionStorage.removeItem('ut_admin_session');await loadPublic();await loadPrivate();ready=true;rerender()}
  client.auth.onAuthStateChange(async(event,newSession)=>{if(event!=='PASSWORD_RECOVERY')return;session=newSession;const password=prompt('Escribí tu nueva contraseña (mínimo 8 caracteres):');if(!password)return;if(password.length<8){alert('La contraseña debe tener al menos 8 caracteres. Volvé a solicitar el enlace.');return}const {error}=await client.auth.updateUser({password});if(error){alert(`No se pudo actualizar: ${error.message}`);return}alert('Contraseña actualizada. Ya podés ingresar al panel.');history.replaceState({},document.title,location.pathname);sessionStorage.setItem('ut_admin_session','1');rerender()});
  window.urbanCloud={client,init,login,logout,sync};
  window.addEventListener('DOMContentLoaded',init);
})();
