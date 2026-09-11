(function(root){
  'use strict';
  const KEY='ut_store_state_v1';
  const closed=o=>['Entregado','Cancelado'].includes(o.status);
  const paid=o=>o.stock_applied===true && Boolean(o.external_payment_id);
  function subtractPurchased(cart,items){
    const quantities=new Map(items.map(x=>[x.product_id,Number(x.quantity)]));
    return cart.map(x=>({...x,qty:Math.max(0,Number(x.qty)-(quantities.get(x.id)||0))})).filter(x=>x.qty>0);
  }
  function state(){const stored=localStorage.getItem(KEY);return stored?JSON.parse(stored):{items:JSON.parse(localStorage.getItem('ut_cart_v3')||'[]'),pending:[],settled:[]}}
  function persist(s){localStorage.setItem(KEY,JSON.stringify(s));localStorage.setItem('ut_cart_v3',JSON.stringify(s.items))}
  function loadCart(){return state().items}
  function saveCart(items){const s=state();s.items=items;persist(s)}
  function remember(result,items){const s=state();if(!result.checkoutToken)throw new Error('Falta actualizar la función de pagos antes de continuar.');s.pending.push({id:result.orderId,token:result.checkoutToken,items,createdAt:Date.now()});persist(s)}
  function settle(s,id,items){if(s.settled.includes(id))return s;return {...s,items:subtractPurchased(s.items,items),pending:s.pending.filter(p=>p.id!==id),settled:[...s.settled,id]}}
  function day(value){if(!value)return '';if(/^\d{4}-\d{2}-\d{2}$/.test(value))return value;const d=new Date(value);if(!Number.isFinite(+d))return '';return new Intl.DateTimeFormat('en-CA',{timeZone:'America/Argentina/Buenos_Aires',year:'numeric',month:'2-digit',day:'2-digit'}).format(d)}
  function summarize({orders=[],bookings=[],history=[],products=[],period='30',now=new Date()}){
    const today=day(now.toISOString()),cutoff=period==='all'?'0000-00-00':day(new Date(+now-(Number(period)-1)*86400000).toISOString());
    const inPeriod=d=>d&&d>=cutoff&&d<=today,serviceMap=new Map(),productMap=new Map(),trend=new Map();
    const histories=new Set(history.map(h=>h.bookingId).filter(Boolean));
    const byId=new Map(bookings.map(b=>[b.id,b]));
    const services=[...history.map(h=>({...h,amount:h.amount??byId.get(h.bookingId)?.finalPrice})),...bookings.filter(b=>b.status==='Completado'&&!histories.has(b.id)).map(b=>({service:b.service,date:b.date,amount:b.finalPrice}))].filter(h=>inPeriod(day(h.date)));
    let missingAmounts=0;
    function addTrend(date,kind,value){const key=date.slice(0,7),row=trend.get(key)||{name:key,services:0,products:0};row[kind]+=value;trend.set(key,row)}
    for(const h of services){const amount=h.amount==null||h.amount===''?null:Number(h.amount),known=amount!==null&&Number.isFinite(amount)&&amount>=0,row=serviceMap.get(h.service)||{name:h.service,count:0,revenue:0,known:0};row.count++;if(known){row.revenue+=amount;row.known++;addTrend(day(h.date),'services',amount)}else missingAmounts++;serviceMap.set(h.service,row)}
    const sales=orders.filter(o=>paid(o)&&!['Cancelado'].includes(o.status)&&inPeriod(day(o.paid_at||o.created_at)));
    for(const o of sales)for(const i of o.order_items||[]){const p=products.find(p=>p.id===i.product_id),qty=Number(i.quantity),revenue=qty*Number(i.unit_price),known=p?.cost!==''&&p?.cost!=null&&Number.isFinite(Number(p.cost)),row=productMap.get(i.product_id)||{id:i.product_id,name:i.product_name,units:0,revenue:0,profit:0,missingCost:0};row.units+=qty;row.revenue+=revenue;if(known)row.profit+=revenue-qty*Number(p.cost);else row.missingCost+=qty;productMap.set(i.product_id,row);addTrend(day(o.paid_at||o.created_at),'products',revenue)}
    const serviceRows=[...serviceMap.values()].sort((a,b)=>b.count-a.count),productRows=[...productMap.values()].sort((a,b)=>b.units-a.units);
    return {serviceRows,productRows,trend:[...trend.values()].sort((a,b)=>a.name.localeCompare(b.name)),missingAmounts,serviceRevenue:serviceRows.reduce((n,x)=>n+x.revenue,0),productRevenue:productRows.reduce((n,x)=>n+x.revenue,0),serviceCount:services.length,productUnits:productRows.reduce((n,x)=>n+x.units,0),orderCount:sales.length,lowStock:products.filter(p=>Number(p.stock)<=Number(p.minStock??3)).sort((a,b)=>a.stock-b.stock),cancelled:orders.filter(o=>o.status==='Cancelado'&&inPeriod(day(o.created_at))).length};
  }
  root.UrbanStore={KEY,closed,paid,subtractPurchased,loadCart,saveCart,remember,settle,summarize};
  if(typeof module!=='undefined')module.exports=root.UrbanStore;
  if(typeof window==='undefined')return;
  let checking=false;
  function message(text){let box=document.getElementById('paymentNotice');if(!box){box=document.createElement('div');box.id='paymentNotice';box.className='payment-notice';box.setAttribute('role','status');document.querySelector('header').insertAdjacentElement('afterend',box)}box.textContent=text}
  async function check(){
    if(checking||document.hidden||!window.urbanCloud?.client)return;
    const pending=state().pending;if(!pending.length)return;checking=true;
    try{for(const p of pending){
      const {data,error}=await window.urbanCloud.client.rpc('store_checkout_status',{p_order_id:p.id,p_token:p.token});
      if(error){message('No pudimos verificar el pago todavía. Conservamos tu carrito; no vuelvas a pagar si ya lo abonaste.');continue}
      if(data?.confirmed===true&&Array.isArray(data.items)){
        const commit=()=>{const current=state();if(current.settled.includes(p.id))return;persist(settle(current,p.id,data.items));window.dispatchEvent(new Event('urban:cart-updated'))};
        if(navigator.locks)await navigator.locks.request('urban-cart',commit);else commit();
        message('Compra confirmada. Quitamos del carrito los artículos comprados. Esperá el aviso de que está listo para retirar.');
      }else if(data?.status==='Cancelado'){const current=state();current.pending=current.pending.filter(x=>x.id!==p.id);persist(current);message('El pedido fue cancelado. Los productos siguen en tu carrito.');}
      else message('Tu pago aún no está confirmado. Conservamos los productos en el carrito. Si ya pagaste, no repitas el pago.');
    }}catch{message('No pudimos comprobar el pago. Tu carrito se conserva; volveremos a intentarlo.')}finally{checking=false}
  }
  window.addEventListener('DOMContentLoaded',()=>{check();setInterval(check,15000)});
  window.addEventListener('focus',check);document.addEventListener('visibilitychange',check);
  window.addEventListener('storage',e=>{if(e.key===KEY)window.dispatchEvent(new Event('urban:cart-updated'))});
})(typeof window==='undefined'?globalThis:window);
