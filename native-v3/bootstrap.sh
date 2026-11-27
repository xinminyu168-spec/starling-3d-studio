#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p app/src/main/java/com/starling/filament app/src/main/assets
cat > gradle.properties <<'EOF'
android.useAndroidX=true
org.gradle.jvmargs=-Xmx3g -Dfile.encoding=UTF-8
EOF
cat > settings.gradle <<'EOF'
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS); repositories { google(); mavenCentral() } }
rootProject.name = 'StarlingFilament'
include ':app'
EOF
cat > build.gradle <<'EOF'
plugins {
 id 'com.android.application' version '8.7.3' apply false
 id 'org.jetbrains.kotlin.android' version '2.0.21' apply false
}
EOF
cat > app/build.gradle <<'EOF'
plugins { id 'com.android.application'; id 'org.jetbrains.kotlin.android' }
android {
 namespace 'com.starling.filament'
 compileSdk 35
 defaultConfig {
  applicationId 'com.xs.character.viewer'
  minSdk 26
  targetSdk 32
  versionCode 62
  versionName '6.0'
  ndk { abiFilters 'arm64-v8a' }
 }
 compileOptions { sourceCompatibility JavaVersion.VERSION_17; targetCompatibility JavaVersion.VERSION_17 }
 kotlinOptions { jvmTarget = '17' }
}
dependencies {
 implementation 'androidx.core:core:1.13.1'
 implementation 'com.google.android.filament:filament-android:1.56.0'
 implementation 'com.google.android.filament:gltfio-android:1.56.0'
 implementation 'com.google.android.filament:filament-utils-android:1.56.0'
}
EOF
cat > app/src/main/AndroidManifest.xml <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
 <uses-permission android:name="android.permission.INTERNET"/>
 <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>
 <uses-feature android:glEsVersion="0x00030000" android:required="true"/>
 <application android:label="星灵 · 3D 查看器" android:theme="@android:style/Theme.Material.NoActionBar" android:allowBackup="false" android:usesCleartextTraffic="false" android:largeHeap="true">
  <provider android:name="androidx.core.content.FileProvider" android:authorities="com.xs.character.viewer.updates" android:exported="false" android:grantUriPermissions="true"><meta-data android:name="android.support.FILE_PROVIDER_PATHS" android:resource="@xml/update_paths"/></provider>
  <activity android:name="com.starling.filament.MainActivity" android:exported="true" android:configChanges="orientation|screenSize|keyboardHidden">
   <intent-filter><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent-filter>
  </activity>
 </application>
</manifest>
EOF
cat > app/src/main/java/com/starling/filament/MainActivity.kt <<'EOF'
package com.starling.filament
import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.view.*
import android.widget.*
import android.graphics.Color
import com.google.android.filament.*
import com.google.android.filament.utils.ModelViewer
import com.google.android.filament.utils.Utils
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import org.json.JSONObject

class MainActivity : Activity() {
 companion object { init { Utils.init() } }
 private lateinit var viewer: ModelViewer
 private lateinit var status: TextView
 private lateinit var surface: SurfaceView
 private lateinit var ibl: IndirectLight
 private var active = false
 private lateinit var appUpdates: AppUpdates
 private var selected = "full"
 private var modelVersion = ""
 private var resourcePrompted = ""
 private var resourceDialog: android.app.AlertDialog? = null
 private var checking = false
 private var version = ""
 private var lastCheck = 0L
 private val frames = Choreographer.getInstance()
 private val ticker = object : Choreographer.FrameCallback {
  override fun doFrame(t: Long) {
   if (!active) return
   if(spinning&&!exportBusy){yaw=(yaw+0.45f)%360f;applyTransform()}
   viewer.render(t)
   loadProgress()
   if (t-lastCheck>30_000_000_000L) { lastCheck=t; if(initialized&&!pausedResources)sync() }
   frames.postFrameCallback(this)
  }
 }
 private lateinit var web:android.webkit.WebView
 private var initialized=false
 private var loadBuffer:ByteBuffer?=null
 private var loading=false
 private var exportBusy=false
 private var maxPresetPending=false
 private var eyePreparing=false
 private var eyeActive=false
 private var irisBoundSlots=0
 private var irisLastResult="尚未启用"
 private var lightProfile=0
 private var advancedMask=0
 private var loadStart=0L
 private var lastLoadPercent=-1
 private var diagnostic=false
 private var uvResult="尚未运行"
 private var uvProbeShader:Material?=null
 private var uvProbeInstance:MaterialInstance?=null
 private val uvProbeBindings=mutableListOf<SkinBinding>()
 private var modelAudit=""
 private val explicitTextures=mutableListOf<Texture>()
 private val boundAtlas=mutableMapOf<String,Texture>()
 private var skinShader:Material?=null
 private var hairShader:Material?=null
 private var shellShader:Material?=null
 private var shellInstance:MaterialInstance?=null
 private val shellBindings=mutableListOf<SkinBinding>()
 private var clothShader:Material?=null
 private var clothInstance:MaterialInstance?=null
 private val clothBindings=mutableListOf<SkinBinding>()
 private var hairInstance:MaterialInstance?=null
 private val hairBindings=mutableListOf<SkinBinding>()
 private var sssInstance:MaterialInstance?=null
 private data class SkinBinding(val entity:Int,val primitive:Int,val original:MaterialInstance)
 private val skinBindings=mutableListOf<SkinBinding>()
 private data class Atlas(val parameter:String,val image:ByteArray,val srgb:Boolean)
 private var pendingAtlas=listOf<Atlas>()
 private fun clearExplicit(){irisBoundSlots=0;uvProbeBindings.clear();uvProbeInstance?.let{viewer.engine.destroyMaterialInstance(it)};uvProbeInstance=null;shellBindings.clear();shellInstance?.let{viewer.engine.destroyMaterialInstance(it)};shellInstance=null;clothBindings.clear();clothInstance?.let{viewer.engine.destroyMaterialInstance(it)};clothInstance=null;hairBindings.clear();hairInstance?.let{viewer.engine.destroyMaterialInstance(it)};hairInstance=null;skinMaterials.clear();skinBindings.clear();sssInstance?.let{viewer.engine.destroyMaterialInstance(it)};sssInstance=null;boundAtlas.clear();for(t in explicitTextures)viewer.engine.destroyTexture(t);explicitTextures.clear();pendingAtlas=emptyList()}
 // The shared atlas has no semantic material ID. Only refine conservative
 // colour/roughness candidates; do not relabel arbitrary regions as skin/cloth.
 private fun decodedAtlas(a:Atlas,mutable:Boolean=false):android.graphics.Bitmap{
  val opts=android.graphics.BitmapFactory.Options().apply{
   inPreferredConfig=android.graphics.Bitmap.Config.ARGB_8888;inScaled=false;inMutable=mutable
   inPreferredColorSpace=android.graphics.ColorSpace.get(android.graphics.ColorSpace.Named.SRGB)
  }
  return android.graphics.BitmapFactory.decodeByteArray(a.image,0,a.image.size,opts)?:error("Android 图片解码失败："+a.parameter)
 }
 private fun ramp(x:Float,lo:Float,hi:Float):Float=((x-lo)/(hi-lo)).coerceIn(0f,1f).let{it*it*(3f-2f*it)}
 private fun refineMaterialMap(bmp:android.graphics.Bitmap,base:android.graphics.Bitmap):Long{
  if(base.width!=bmp.width||base.height!=bmp.height)return 0
  val w=bmp.width;val h=bmp.height
  val src=IntArray(w);val mr=IntArray(w)
  var modified=0L
  for(y in 0 until h){
   base.getPixels(src,0,w,0,y,w,1);bmp.getPixels(mr,0,w,0,y,w,1)
   for(x in 0 until w){
    val c=src[x];val m=mr[x]
    val r=((c ushr 16) and 255).toFloat();val g=((c ushr 8) and 255).toFloat();val b=(c and 255).toFloat()
    val metal=(m and 255).toFloat();val rough=((m ushr 8) and 255).toFloat()
    val dielectric=1f-ramp(metal,5f,24f)
    val warm=dielectric*ramp(r,108f,150f)*ramp(r-g,12f,32f)*ramp(g-b,6f,20f)*ramp(r-b,25f,55f)
    val cool=dielectric*ramp(b,80f,125f)*ramp(b-r,25f,65f)*ramp(b-g,12f,38f)*ramp(rough,120f,155f)
    // Smoothly lift roughness in already matte areas. No base-colour or metal change.
    // Existing baked roughness detail is retained; delta is at most 18/255.
    val delta=warm*9f+cool*18f
    val adjusted=(rough+delta+.5f).toInt().coerceIn(0,255)
    if(adjusted!=rough.toInt()){mr[x]=(m and 0xffff00ff.toInt()) or (adjusted shl 8);modified++}
   }
   bmp.setPixels(mr,0,w,0,y,w,1)
  }
  return modified
 }
 private fun bindAtlas(){
  val asset=viewer.asset?:error("无可绑定模型")
  val rm=viewer.engine.renderableManager
  val instances=mutableListOf<MaterialInstance>()
  for(entity in asset.entities){val ri=rm.getInstance(entity);if(ri==0)continue;for(i in 0 until rm.getPrimitiveCount(ri))instances.add(rm.getMaterialInstanceAt(ri,i))}
  require(instances.isNotEmpty()){"无材质实例"}
  val notes=mutableListOf<String>()
  val baseAtlas=pendingAtlas.firstOrNull{it.parameter=="baseColorMap"}
  for(a in pendingAtlas){
   val targets=instances.filter{it.material.hasParameter(a.parameter)}
   require(targets.isNotEmpty()){"缺少采样器 "+a.parameter}
   val polish=refineAtlas&&cinematic&&!diagnostic&&a.parameter=="metallicRoughnessMap"&&baseAtlas!=null
   val bmp=decodedAtlas(a,polish)
   if(polish){
    val base=decodedAtlas(baseAtlas!!)
    try{val changed=refineMaterialMap(bmp,base);notes.add("局部粗糙度精修 "+changed+" 像素")}finally{base.recycle()}
   }
   val w=bmp.width;val h=bmp.height;require(w in 1..4096&&h in 1..4096)
   val levels=32-Integer.numberOfLeadingZeros(maxOf(w,h))
   val tex=Texture.Builder().width(w).height(h).levels(levels).sampler(Texture.Sampler.SAMPLER_2D).format(if(a.srgb)Texture.InternalFormat.SRGB8_A8 else Texture.InternalFormat.RGBA8).build(viewer.engine)
   explicitTextures.add(tex)
   boundAtlas[a.parameter]=tex
   com.google.android.filament.android.TextureHelper.setBitmap(viewer.engine,tex,0,bmp,android.os.Handler(mainLooper),Runnable{bmp.recycle()})
   tex.generateMipmaps(viewer.engine)
   val sampler=TextureSampler(TextureSampler.MinFilter.LINEAR_MIPMAP_LINEAR,TextureSampler.MagFilter.LINEAR,TextureSampler.WrapMode.REPEAT)
   sampler.setAnisotropy(8f)
   for(mi in targets){mi.setParameter(a.parameter,tex,sampler)}
   notes.add(a.parameter+" "+w+"×"+h)
  }
  require(notes.isNotEmpty()){"未绑定任何纹理"}
  if(regionModel)notes.add(refineRegions(instances))
  if(eyeActive)notes.add(bindIrisParameters(instances))
  modelAudit+="\nAndroid 独立解码与显式绑定："+notes.joinToString("；")
  pendingAtlas=emptyList()
 }
 private fun bindIrisParameters(instances:List<MaterialInstance>):String{
  val names=setOf("Iris_candidate_General","Iris_candidate_Skin_candidate")
  val iris=instances.filter{it.name in names}
  require(iris.map{it.name}.toSet()==names){"虹膜候选材质未完整绑定"}
  val params=listOf("metallicFactor","roughnessFactor","normalScale")
  require(iris.all{mi->params.all{mi.material.hasParameter(it)}}){"虹膜 PBR 参数不兼容"}
  for(mi in iris){
   mi.setParameter("metallicFactor",0f)
   mi.setParameter("roughnessFactor",.65f)
   mi.setParameter("normalScale",.20f)
  }
  irisBoundSlots=iris.size
  irisLastResult="已绑定 2 个候选材质 / "+irisBoundSlots+" 个图元实例"
  return "虹膜 PBR："+irisLastResult+"；金属度倍率 0，粗糙度倍率 0.65，法线强度 0.20"
 }
 // The actual glTF instance labels are supplied by AssetLoader; unknown names
 // always retain the original glTF values. No whole-model metal or color override.
 private fun refineRegions(instances:List<MaterialInstance>):String{
  val applied=mutableSetOf<String>()
  skinMaterials.clear()
  for(mi in instances){
   val label=mi.name?:""
   val normal=when(label){
    "Skin_candidate"->.40f
    "Hair_candidate"->.48f
    "Blue_fabric_candidate"->.62f
    "Painted_shell_candidate"->.48f
    else->continue
   }
   if(label=="Skin_candidate")skinMaterials.add(mi)
   if(mi.material.hasParameter("normalScale"))mi.setParameter("normalScale",normal)
   if(mi.material.hasParameter("roughnessFactor")){
    val factor=when(label){"Painted_shell_candidate"->.94f;"Hair_candidate"->.97f;else->1f}
    mi.setParameter("roughnessFactor",factor)
   }
   // Keep the authored metallic texture and factor for all slots.
   applied.add(label)
  }
  require(applied.size==4){"分区材质名称未完整匹配："+applied.joinToString(",")}
  applySkinDetail()
  return "独立候选材质 "+applied.size+" 个："+applied.joinToString(",")
 }
 // This is a bounded PBR surface adjustment, not subsurface scattering.
 // The candidate slot alone is adjusted; no base color or metallic override.
 private fun applySkinDetail(){
  if(!regionModel||diagnostic)return
  val t=skinSoftness.coerceIn(0f,1f)
  sssInstance?.setParameter("softness",t)
  for(mi in skinMaterials){
   if(mi.material.hasParameter("normalScale"))mi.setParameter("normalScale",.55f-.32f*t)
   if(mi.material.hasParameter("roughnessFactor"))mi.setParameter("roughnessFactor",1f-.08f*(1f-t))
  }
 }
 // Opt-in shader until real-device visual verification passes.
 private fun installSkinShader():String{
  if(!regionModel||diagnostic||loading)return "请先加载高精度分区模型"
  if(sssInstance!=null)return "皮肤散射已开启"
  val asset=viewer.asset?:return "无可用模型"
  val rm=viewer.engine.renderableManager
  var created:MaterialInstance?=null
  try{
   val material=skinShader?:run{
    val bytes=resources.openRawResource(R.raw.studio_skin).use{it.readBytes()}
    val buffer=ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder());buffer.put(bytes);buffer.flip()
    Material.Builder().payload(buffer,bytes.size).build(viewer.engine).also{skinShader=it}
   }
   val eligible=mutableListOf<SkinBinding>()
   for(entity in asset.entities){
    val ri=rm.getInstance(entity);if(ri==0)continue
    for(i in 0 until rm.getPrimitiveCount(ri)){
     val old=rm.getMaterialInstanceAt(ri,i)
     if(old.name!="Skin_candidate")continue
     require(rm.getEnabledAttributesAt(ri,i).containsAll(material.requiredAttributes)){"皮肤顶点属性不兼容"}
     eligible.add(SkinBinding(entity,i,old))
    }
   }
   require(eligible.isNotEmpty()){"未找到皮肤候选分区"}
   val mi=material.createInstance("Studio_skin_SSS");created=mi
   val sampler=TextureSampler(TextureSampler.MinFilter.LINEAR_MIPMAP_LINEAR,TextureSampler.MagFilter.LINEAR,TextureSampler.WrapMode.REPEAT)
   sampler.setAnisotropy(8f)
   for(name in listOf("baseColorMap","normalMap","metallicRoughnessMap"))mi.setParameter(name,boundAtlas[name]?:error("缺少皮肤图集 "+name),sampler)
   mi.setParameter("softness",skinSoftness)
   mi.setParameter("poreStrength",poreStrength)
   for(binding in eligible){skinBindings.add(binding);rm.setMaterialInstanceAt(rm.getInstance(binding.entity),binding.primitive,mi)}
   sssInstance=mi
   return "独立 Subsurface 着色器 · "+eligible.size+" 个图元"
  }catch(e:Exception){
   for(binding in skinBindings){val ri=rm.getInstance(binding.entity);if(ri!=0)rm.setMaterialInstanceAt(ri,binding.primitive,binding.original)}
   skinBindings.clear();created?.let{viewer.engine.destroyMaterialInstance(it)};sssInstance=null
   return "皮肤散射未启用，保留原 PBR："+e.message
  }
 }
 private fun disableSkinShader(){
  val rm=viewer.engine.renderableManager
  for(binding in skinBindings){val ri=rm.getInstance(binding.entity);if(ri!=0)rm.setMaterialInstanceAt(ri,binding.primitive,binding.original)}
  skinBindings.clear();sssInstance?.let{viewer.engine.destroyMaterialInstance(it)};sssInstance=null
 }
 private fun installHairShader():String{
  if(!regionModel||diagnostic||loading)return "请先加载高精度分区模型"
  if(hairInstance!=null)return "发束反射已开启"
  val asset=viewer.asset?:return "无可用模型"
  val rm=viewer.engine.renderableManager
  var created:MaterialInstance?=null
  try{
   val material=hairShader?:run{
    val bytes=resources.openRawResource(R.raw.studio_hair).use{it.readBytes()}
    val buffer=ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder());buffer.put(bytes);buffer.flip()
    Material.Builder().payload(buffer,bytes.size).build(viewer.engine).also{hairShader=it}
   }
   val eligible=mutableListOf<SkinBinding>()
   for(entity in asset.entities){
    val ri=rm.getInstance(entity);if(ri==0)continue
    for(i in 0 until rm.getPrimitiveCount(ri)){
     val old=rm.getMaterialInstanceAt(ri,i)
     if(old.name!="Hair_candidate")continue
     require(rm.getEnabledAttributesAt(ri,i).containsAll(material.requiredAttributes)){"发束顶点属性不兼容"}
     eligible.add(SkinBinding(entity,i,old))
    }
   }
   require(eligible.isNotEmpty()){"未找到头发候选分区"}
   val mi=material.createInstance("Studio_hair_anisotropic");created=mi
   val sampler=TextureSampler(TextureSampler.MinFilter.LINEAR_MIPMAP_LINEAR,TextureSampler.MagFilter.LINEAR,TextureSampler.WrapMode.REPEAT)
   sampler.setAnisotropy(8f)
   for(name in listOf("baseColorMap","normalMap","metallicRoughnessMap"))mi.setParameter(name,boundAtlas[name]?:error("缺少头发图集 "+name),sampler)
   mi.setParameter("strength",0.55f)
   for(binding in eligible){hairBindings.add(binding);rm.setMaterialInstanceAt(rm.getInstance(binding.entity),binding.primitive,mi)}
   hairInstance=mi
   return "独立各向异性着色器 · "+eligible.size+" 个图元"
  }catch(e:Exception){
   for(binding in hairBindings){val ri=rm.getInstance(binding.entity);if(ri!=0)rm.setMaterialInstanceAt(ri,binding.primitive,binding.original)}
   hairBindings.clear();created?.let{viewer.engine.destroyMaterialInstance(it)};hairInstance=null
   return "发束反射未启用，保留原 PBR："+e.message
  }
 }
 private fun disableHairShader(){
  val rm=viewer.engine.renderableManager
  for(binding in hairBindings){val ri=rm.getInstance(binding.entity);if(ri!=0)rm.setMaterialInstanceAt(ri,binding.primitive,binding.original)}
  hairBindings.clear();hairInstance?.let{viewer.engine.destroyMaterialInstance(it)};hairInstance=null
 }
 private fun installClothShader():String{
  if(!regionModel||diagnostic||loading)return "请先加载高精度分区模型"
  if(clothInstance!=null)return "织物微表面已开启"
  val asset=viewer.asset?:return "无可用模型"
  val rm=viewer.engine.renderableManager
  var created:MaterialInstance?=null
  try{
   val material=clothShader?:run{
    val bytes=resources.openRawResource(R.raw.studio_cloth).use{it.readBytes()}
    val buffer=ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder());buffer.put(bytes);buffer.flip()
    Material.Builder().payload(buffer,bytes.size).build(viewer.engine).also{clothShader=it}
   }
   val eligible=mutableListOf<SkinBinding>()
   for(entity in asset.entities){
    val ri=rm.getInstance(entity);if(ri==0)continue
    for(i in 0 until rm.getPrimitiveCount(ri)){
     val old=rm.getMaterialInstanceAt(ri,i)
     if(old.name!="Blue_fabric_candidate")continue
     require(rm.getEnabledAttributesAt(ri,i).containsAll(material.requiredAttributes)){"织物微表面顶点属性不兼容"}
     eligible.add(SkinBinding(entity,i,old))
    }
   }
   require(eligible.isNotEmpty()){"未找到织物微表面候选分区"}
   val mi=material.createInstance("Studio_cloth_sheen");created=mi
   val sampler=TextureSampler(TextureSampler.MinFilter.LINEAR_MIPMAP_LINEAR,TextureSampler.MagFilter.LINEAR,TextureSampler.WrapMode.REPEAT)
   sampler.setAnisotropy(8f)
   for(name in listOf("baseColorMap","normalMap","metallicRoughnessMap"))mi.setParameter(name,boundAtlas[name]?:error("缺少织物微表面图集 "+name),sampler)
   mi.setParameter("strength",0.55f)
   for(binding in eligible){clothBindings.add(binding);rm.setMaterialInstanceAt(rm.getInstance(binding.entity),binding.primitive,mi)}
   clothInstance=mi
   return "织物微表面着色器 · "+eligible.size+" 个图元"
  }catch(e:Exception){
   for(binding in clothBindings){val ri=rm.getInstance(binding.entity);if(ri!=0)rm.setMaterialInstanceAt(ri,binding.primitive,binding.original)}
   clothBindings.clear();created?.let{viewer.engine.destroyMaterialInstance(it)};clothInstance=null
   return "织物微表面未启用，保留原 PBR："+e.message
  }
 }
 private fun disableClothShader(){
  val rm=viewer.engine.renderableManager
  for(binding in clothBindings){val ri=rm.getInstance(binding.entity);if(ri!=0)rm.setMaterialInstanceAt(ri,binding.primitive,binding.original)}
  clothBindings.clear();clothInstance?.let{viewer.engine.destroyMaterialInstance(it)};clothInstance=null
 }
 private fun installShellShader():String{
  if(!regionModel||diagnostic||loading)return "请先加载高精度分区模型"
  if(shellInstance!=null)return "外壳双层烤漆已开启"
  val asset=viewer.asset?:return "无可用模型"
  val rm=viewer.engine.renderableManager
  var created:MaterialInstance?=null
  try{
   val material=shellShader?:run{
    val bytes=resources.openRawResource(R.raw.studio_shell).use{it.readBytes()}
    val buffer=ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder());buffer.put(bytes);buffer.flip()
    Material.Builder().payload(buffer,bytes.size).build(viewer.engine).also{shellShader=it}
   }
   val eligible=mutableListOf<SkinBinding>()
   for(entity in asset.entities){
    val ri=rm.getInstance(entity);if(ri==0)continue
    for(i in 0 until rm.getPrimitiveCount(ri)){
     val old=rm.getMaterialInstanceAt(ri,i)
     if(old.name!="Painted_shell_candidate")continue
     require(rm.getEnabledAttributesAt(ri,i).containsAll(material.requiredAttributes)){"外壳双层烤漆顶点属性不兼容"}
     eligible.add(SkinBinding(entity,i,old))
    }
   }
   require(eligible.isNotEmpty()){"未找到外壳双层烤漆候选分区"}
   val mi=material.createInstance("Studio_shell_clearcoat");created=mi
   val sampler=TextureSampler(TextureSampler.MinFilter.LINEAR_MIPMAP_LINEAR,TextureSampler.MagFilter.LINEAR,TextureSampler.WrapMode.REPEAT)
   sampler.setAnisotropy(8f)
   for(name in listOf("baseColorMap","normalMap","metallicRoughnessMap"))mi.setParameter(name,boundAtlas[name]?:error("缺少外壳双层烤漆图集 "+name),sampler)
   mi.setParameter("strength",0.55f)
   for(binding in eligible){shellBindings.add(binding);rm.setMaterialInstanceAt(rm.getInstance(binding.entity),binding.primitive,mi)}
   shellInstance=mi
   return "外壳双层烤漆着色器 · "+eligible.size+" 个图元"
  }catch(e:Exception){
   for(binding in shellBindings){val ri=rm.getInstance(binding.entity);if(ri!=0)rm.setMaterialInstanceAt(ri,binding.primitive,binding.original)}
   shellBindings.clear();created?.let{viewer.engine.destroyMaterialInstance(it)};shellInstance=null
   return "外壳双层烤漆未启用，保留原 PBR："+e.message
  }
 }
 private fun disableShellShader(){
  val rm=viewer.engine.renderableManager
  for(binding in shellBindings){val ri=rm.getInstance(binding.entity);if(ri!=0)rm.setMaterialInstanceAt(ri,binding.primitive,binding.original)}
  shellBindings.clear();shellInstance?.let{viewer.engine.destroyMaterialInstance(it)};shellInstance=null
 }
 private fun fallbackRegion(reason:String):Boolean{
  if(!regionModel)return false
  if(eyeActive){irisLastResult="试验失败，恢复原分区："+reason;eyeActive=false;js("window.studioIris&&studioIris(false)");if(loadAsset("native_full.glb"))return true}
  regionModel=false
  status.text="分区加载失败，恢复原模型："+reason
  return loadAsset("full.glb")
 }
 private fun loadProgress(){
  if(!loading)return
  val p=viewer.progress.coerceIn(0f,1f)
  val percent=(p*100).toInt()
  if(percent!=lastLoadPercent){lastLoadPercent=percent;js("window.studioProgress&&studioProgress("+percent+")")}
  if(p>=.9999f){
   loading=false;loadBuffer=null
   try{bindAtlas()}catch(e:Exception){
    if(fallbackRegion(e.message?:"纹理绑定异常"))return
    status.text="显式纹理绑定失败："+e.message;js("window.studioFailure&&studioFailure("+JSONObject.quote(status.text.toString())+")");return
   }
   applyStudioLook()
   js("window.studioIris&&studioIris("+eyeActive+")")
   if(eyeActive)modelAudit+="\n虹膜试验：69 个候选面 · 原模型未覆盖"
   val presetReport=if(maxPresetPending){maxPresetPending=false;"最高画质 · 原 PBR 安全模式；请逐项测试高级材质"}else null
   status.text=presetReport?:if(eyeActive)"虹膜反射试验 · "+irisLastResult else if(diagnostic)"仅色彩图诊断 · 已加载" else if(cinematic)"影视渲染 · 纹理绑定完成" else "保真渲染 · 纹理绑定完成"
   js("studioLoaded("+JSONObject.quote(selected)+");window.studioDiagnostic&&studioDiagnostic("+diagnostic+");window.studioRegions&&studioRegions("+regionModel+");window.studioSSS&&studioSSS("+(sssInstance!=null)+");window.studioHair&&studioHair("+(hairInstance!=null)+");window.studioCloth&&studioCloth("+(clothInstance!=null)+");window.studioShell&&studioShell("+(shellInstance!=null)+")")
  }else if(android.os.SystemClock.elapsedRealtime()-loadStart>60000L){
   loading=false
   viewer.destroyModel();clearExplicit();loadBuffer=null
   if(fallbackRegion("纹理加载超时"))return
   status.text="纹理加载超时，请切换轻量模型"
   js("window.studioFailure&&studioFailure("+JSONObject.quote(status.text.toString())+")")
  }
 }
 private var baseTransform:FloatArray?=null
 private var yaw=0f
 private var pitch=0f
 private var zoom=1f
 private var panX=0f
 private var panY=0f
 private var spinning=false
 private var exp=1.04f
 private var keyPower=1f
 private var ambientPower=1f
 private var reflectPower=.85f
 private var envTexture:Texture?=null
 private var envSH:FloatArray?=null
 private var lastAmbient=-1f
 private var lastReflect=-1f
 private var rough=1.13f
 private var normal=0.38f
 private var flat=false
 private var cinematic=true
 private var refineAtlas=true
 private var regionModel=false
 private var skinSoftness=.55f
 private var poreStrength=.35f
 private val skinMaterials=mutableListOf<MaterialInstance>()
 private var qualityLevel=2.0
 private var cinematicGrading:ColorGrading?=null
 private var neutralGrading:ColorGrading?=null
 private var mainLamp=0
 private var fillLamp=0
 private var rimLamp=0
 private var pausedResources=false
 private val prefs by lazy { getSharedPreferences("studio_ui",0) }
 private fun js(code:String){if(::web.isInitialized&&!isDestroyed)web.evaluateJavascript(code,null)}
 override fun onCreate(savedInstanceState: Bundle?) {
  super.onCreate(savedInstanceState)
  window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or WindowManager.LayoutParams.FLAG_FULLSCREEN)
  val frame=FrameLayout(this)
  frame.setBackgroundColor(Color.rgb(16,20,27))
  surface=SurfaceView(this)
  frame.addView(surface,FrameLayout.LayoutParams(-1,-1))
  web=android.webkit.WebView(this)
  web.setBackgroundColor(Color.TRANSPARENT)
  web.settings.javaScriptEnabled=true
  web.settings.domStorageEnabled=true
  web.settings.allowFileAccess=false
  web.settings.allowContentAccess=false
  web.settings.allowFileAccessFromFileURLs=false
  web.settings.allowUniversalAccessFromFileURLs=false
  web.addJavascriptInterface(Controls(),"Studio")
  frame.addView(web,FrameLayout.LayoutParams(-1,-1))
  setContentView(frame)
  appUpdates=AppUpdates(this)
  status=TextView(this)
  status.addTextChangedListener(object:android.text.TextWatcher{
   override fun beforeTextChanged(s:CharSequence?,start:Int,count:Int,after:Int){}
   override fun onTextChanged(s:CharSequence?,start:Int,before:Int,count:Int){js("window.studioStatus&&studioStatus("+JSONObject.quote(s.toString())+")")}
   override fun afterTextChanged(s:android.text.Editable?){}
  })
  viewer=ModelViewer(surface)
  val engine=viewer.engine
  ibl=IndirectLight.Builder().irradiance(1,floatArrayOf(0.65f,0.68f,0.72f)).intensity(18000f).build(engine)
  viewer.scene.indirectLight=ibl
  try{
   val bytes=assets.open("studio_ibl.ktx").use{it.readBytes()}
   val b=ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder());b.put(bytes);b.flip()
   val env=com.google.android.filament.utils.KTX1Loader.createIndirectLight(engine,b)
   env.intensity=22000f
   val previous=ibl
   viewer.scene.indirectLight=env
   ibl=env
   engine.destroyIndirectLight(previous)
  }catch(e:Exception){status.text="HDR 环境载入失败，使用基础环境光"}
  viewer.scene.skybox=Skybox.Builder().color(0f,0f,0f,1f).build(engine)
  viewer.view.ambientOcclusion=com.google.android.filament.View.AmbientOcclusion.NONE
  viewer.view.antiAliasing=com.google.android.filament.View.AntiAliasing.FXAA
  viewer.view.renderQuality=viewer.view.renderQuality.apply { hdrColorBuffer=com.google.android.filament.View.QualityLevel.HIGH }
  viewer.view.dynamicResolutionOptions=viewer.view.dynamicResolutionOptions.apply { enabled=false }
  viewer.view.multiSampleAntiAliasingOptions=viewer.view.multiSampleAntiAliasingOptions.apply { enabled=true; sampleCount=4 }
  val lm=engine.lightManager
  lm.setIntensity(lm.getInstance(viewer.light),0f)
  lm.setShadowCaster(lm.getInstance(viewer.light),false)
  mainLamp=addStudioLight(.58f,-.58f,-.58f,46000f,1f,.96f,.92f,true)
  fillLamp=addStudioLight(-.6f,-.22f,-.8f,20000f,.93f,.97f,1f,false)
  rimLamp=addStudioLight(-.38f,-.5f,.78f,30000f,.87f,.94f,1f,false)
  cinematicGrading=ColorGrading.Builder().quality(ColorGrading.QualityLevel.ULTRA).toneMapping(ColorGrading.ToneMapping.ACES).saturation(.94f).contrast(1.025f).build(engine)
  neutralGrading=ColorGrading.Builder().quality(ColorGrading.QualityLevel.HIGH).toneMapping(ColorGrading.ToneMapping.LINEAR).saturation(1f).contrast(1f).build(engine)
  applyStudioLook()
  web.webViewClient=object:android.webkit.WebViewClient(){
   override fun shouldOverrideUrlLoading(view:android.webkit.WebView,request:android.webkit.WebResourceRequest)=true
   override fun shouldInterceptRequest(view:android.webkit.WebView,request:android.webkit.WebResourceRequest):android.webkit.WebResourceResponse{
    val u=request.url
    val name=u.path?.removePrefix("/studio/")?:""
    if(u.scheme!="https"||u.host!="appassets.androidplatform.net"||name !in listOf("viewer.html","reference.png"))return android.webkit.WebResourceResponse("text/plain","UTF-8",403,"Forbidden",emptyMap(),java.io.ByteArrayInputStream(ByteArray(0)))
    return try{
     if(name=="reference.png")android.webkit.WebResourceResponse("image/png",null,StudioAssets.file(this@MainActivity,name).inputStream())
     else {
      val original=StudioAssets.file(this@MainActivity,"viewer.html").readText()
      val ui=original.substringBefore("<script").replace("V2.3","V6.0").replace("前台每30秒检查资源；回退后暂停，手动同步可恢复。不更新 APP 程序。","自动检测版本，确认后才下载更新。").replace("检查并同步","检查更新")
      val script=assets.open("studio-controls.js").bufferedReader().use{it.readText()}
      val html=ui+"<style>html,body,canvas{background:transparent!important}body.compare canvas{margin-left:43%;width:57%}</style><script>"+script+"</script></body></html>"
      android.webkit.WebResourceResponse("text/html","UTF-8",java.io.ByteArrayInputStream(html.toByteArray(Charsets.UTF_8)))
     }
    }catch(e:Exception){android.webkit.WebResourceResponse("text/plain","UTF-8",500,"Error",emptyMap(),java.io.ByteArrayInputStream("资源读取失败".toByteArray()))}
   }
   override fun onPageFinished(view:android.webkit.WebView,url:String){if(initialized)js("window.studioReady&&studioReady()")}
  }
  prepareStartupAssets()
 }
 private fun prepareStartupAssets(){
  Thread{
   try{StudioAssets.prepare(this);runOnUiThread{
    if(!isDestroyed){
     initialized=true
     pausedResources=prefs.getBoolean("paused",false)
     cinematic=prefs.getBoolean("cinematic",true)
     refineAtlas=prefs.getBoolean("refineAtlas",true)
     skinSoftness=prefs.getFloat("skinSoftness",.55f)
     poreStrength=prefs.getFloat("poreStrength",.35f).coerceIn(0f,1f)
     applyStudioLook()
     if(!prefs.getBoolean("baseline36",false)){prefs.edit().remove("params").putBoolean("baseline36",true).putBoolean("paused",true).putString("model","full").apply();pausedResources=true}
     if(!prefs.getBoolean("cinematic39",false)){prefs.edit().putString("model","full").putBoolean("cinematic39",true).apply()}
     selected=prefs.getString("model","full")?:"full"
     if(selected!="mobile")selected="full"
     web.loadUrl("https://appassets.androidplatform.net/studio/viewer.html")
     lighting(1.04f,1f,1f)
     loadMode(selected)
     if(active){appUpdates.start();if(!pausedResources)sync()}
    }
   }}catch(e:Exception){runOnUiThread{if(!isDestroyed)showAssetRecovery(e.message?:"未知错误")}}
  }.start()
 }
 private fun showAssetRecovery(reason:String){
  android.app.AlertDialog.Builder(this).setTitle("恢复原模型素材")
   .setMessage("本地资源尚未准备完成："+reason+"\n请选择从旧版备份转换的 Starling-assets.zip。七项资源全部通过 SHA-256 校验后才会恢复。")
   .setPositiveButton("选择素材备份"){_,_->startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*"),81)}
   .setNegativeButton("退出"){_,_->finish()}.setCancelable(false).show()
 }
 private fun applyTransform(){
  val asset=viewer.asset?:return
  val base=baseTransform?:return
  val m=FloatArray(16);val result=FloatArray(16)
  android.opengl.Matrix.setIdentityM(m,0)
  android.opengl.Matrix.translateM(m,0,panX,panY,-4f)
  android.opengl.Matrix.rotateM(m,0,pitch,1f,0f,0f)
  android.opengl.Matrix.rotateM(m,0,yaw,0f,1f,0f)
  android.opengl.Matrix.scaleM(m,0,zoom,zoom,zoom)
  android.opengl.Matrix.translateM(m,0,0f,0f,4f)
  android.opengl.Matrix.multiplyMM(result,0,m,0,base,0)
  val tm=viewer.engine.transformManager
  tm.setTransform(tm.getInstance(asset.root),result)
 }
 private fun setEnvironment(a:Float,r:Float){
  // Keep Filament's calibrated SH and prefiltered reflections together.
  ibl.intensity=22000f*a.coerceIn(.25f,2f)
 }
 private fun applyUiParams(j:JSONObject){
  exp=j.optDouble("exposure",1.04).toFloat().coerceIn(.55f,1.7f)
  keyPower=j.optDouble("key",1.0).toFloat().coerceIn(0f,2f)
  ambientPower=j.optDouble("ambient",1.0).toFloat().coerceIn(0f,2f)
  rough=j.optDouble("rough",1.13).toFloat().coerceIn(.65f,1.6f)
  normal=j.optDouble("normal",.38).toFloat().coerceIn(0f,1f)
  reflectPower=j.optDouble("reflect",.85).toFloat().coerceIn(0f,2f)
  flat=j.optBoolean("flat",false)
  skinSoftness=j.optDouble("skin",.55).toFloat().coerceIn(0f,1f)
  applySkinDetail()
  lighting(exp,if(flat)0f else keyPower,if(flat)2f else ambientPower)
 }
 inner class Controls {
  @android.webkit.JavascriptInterface fun send(command:String,data:String){
   if(data.length>4096)return
   runOnUiThread{
    if(!initialized||isDestroyed)return@runOnUiThread
    if((exportBusy||eyePreparing)&&command!="ready")return@runOnUiThread
    try{
     val j=JSONObject(data)
     when(command){
      "ready"->{js("window.studioIris&&studioIris("+(eyeActive&&!loading)+")");js("window.studioPores&&studioPores("+poreStrength+")");js("window.studioSkin&&studioSkin("+skinSoftness+")");js("window.studioRefine&&studioRefine("+refineAtlas+")");js("window.studioLook&&studioLook("+cinematic+")");js("studioStatus("+JSONObject.quote(status.text.toString())+");studioModel("+JSONObject.quote(selected)+")");if(loading)js("window.studioProgress&&studioProgress("+lastLoadPercent.coerceAtLeast(0)+")") else if(viewer.asset!=null)js("studioLoaded("+JSONObject.quote(selected)+");window.studioDiagnostic&&studioDiagnostic("+diagnostic+");window.studioRegions&&studioRegions("+regionModel+");window.studioSSS&&studioSSS("+(sssInstance!=null)+");window.studioHair&&studioHair("+(hairInstance!=null)+");window.studioCloth&&studioCloth("+(clothInstance!=null)+");window.studioShell&&studioShell("+(shellInstance!=null)+")")}
      "pose"->{yaw=j.optDouble("yaw",0.0).toFloat();pitch=j.optDouble("pitch",0.0).toFloat().coerceIn(-85f,85f);zoom=j.optDouble("zoom",1.0).toFloat().coerceIn(.3f,2.5f);panX=j.optDouble("x",0.0).toFloat().coerceIn(-1.5f,1.5f);panY=j.optDouble("y",0.0).toFloat().coerceIn(-1.5f,1.5f);spinning=j.optBoolean("spin",false);applyTransform()}
      "model"->{val m=j.optString("mode");if(m in listOf("full","mobile")&&(m!=selected||viewer.asset==null)){diagnostic=false;selected=m;prefs.edit().putString("model",m).apply();loadMode(m)}}
      "diagnose"->{
       android.app.AlertDialog.Builder(this@MainActivity).setTitle("纹理加载诊断")
        .setMessage("引擎：Filament 1.56.0\n"+modelAudit+"\n加载进度："+lastLoadPercent.coerceAtLeast(0)+"%\n仅色彩图诊断使用当前规格的临时原始模型，绕过光照、金属度与法线，不修改原文件。进入后点击 UV 采样对照可切换 glTF 原材质与自定义采样器。")
        .setNegativeButton("关闭",null).setPositiveButton(if(diagnostic)"恢复原模型" else "仅色彩图诊断"){_,_->
         if(loading||exportBusy)return@setPositiveButton
         diagnostic=!diagnostic;loadMode(selected)
        }.show()
      }
      "quality"->{qualityLevel=j.optDouble("value",2.0);applyStudioLook()}
      "cinematic"->{val changed=cinematic!=j.optBoolean("enabled",true);cinematic=j.optBoolean("enabled",true);prefs.edit().putBoolean("cinematic",cinematic).apply();applyStudioLook();js("window.studioLook&&studioLook("+cinematic+")");if(changed&&refineAtlas&&!diagnostic)loadMode(selected)}
      "refineAtlas"->{val next=j.optBoolean("enabled",true);if(next!=refineAtlas){refineAtlas=next;prefs.edit().putBoolean("refineAtlas",next).apply();if(!diagnostic)loadMode(selected)};js("window.studioRefine&&studioRefine("+refineAtlas+")")}
      "sss"->{
       if(!loading&&regionModel&&!diagnostic){
        status.text=if(j.optBoolean("enabled",false))installSkinShader()else{disableSkinShader();"已恢复皮肤 PBR"}
       }
       js("window.studioSSS&&studioSSS("+(sssInstance!=null)+");window.studioHair&&studioHair("+(hairInstance!=null)+");window.studioCloth&&studioCloth("+(clothInstance!=null)+");window.studioShell&&studioShell("+(shellInstance!=null)+")")
      }
      "hair"->{
       if(!loading&&regionModel&&!diagnostic){
        status.text=if(j.optBoolean("enabled",false))installHairShader()else{disableHairShader();"已恢复头发 PBR"}
       }
       js("window.studioHair&&studioHair("+(hairInstance!=null)+");window.studioCloth&&studioCloth("+(clothInstance!=null)+");window.studioShell&&studioShell("+(shellInstance!=null)+")")
      }
      "cloth"->{
       if(!loading&&regionModel&&!diagnostic){
        status.text=if(j.optBoolean("enabled",false))installClothShader()else{disableClothShader();"已恢复织物微表面 PBR"}
       }
       js("window.studioCloth&&studioCloth("+(clothInstance!=null)+")")
      }
      "shell"->{
       if(!loading&&regionModel&&!diagnostic){
        status.text=if(j.optBoolean("enabled",false))installShellShader()else{disableShellShader();"已恢复外壳双层烤漆 PBR"}
       }
       js("window.studioShell&&studioShell("+(shellInstance!=null)+")")
      }
      "pores"->{poreStrength=j.optDouble("value",.35).toFloat().coerceIn(0f,1f);sssInstance?.setParameter("poreStrength",poreStrength);prefs.edit().putFloat("poreStrength",poreStrength).apply()}
      "export"->chooseExport()
      "maximum"->maximumPreset()
      "portrait"->portraitPreset()
      "irisTest"->toggleIrisTest()
      "lightProfile"->chooseLightProfile()
      "materialCompare"->compareMaterials()
      "safeMaterials"->restoreSafeMaterials()
      "uvProbe"->toggleUvProbe()
      "uvAuto"->runUvComparison()
      "renderAudit"->showRenderAudit()
      "params"->applyUiParams(j)
      "save"->{prefs.edit().putString("params",data).putFloat("skinSoftness",skinSoftness).apply();status.text="渲染参数已保存"}
      "restore"->{js("studioRestore("+JSONObject.quote(prefs.getString("params","")?:"")+")")}
      "compare"->{val p=surface.layoutParams as FrameLayout.LayoutParams;p.leftMargin=if(j.optBoolean("show"))(web.width*.43f).toInt() else 0;surface.layoutParams=p}
      "check"->{pausedResources=false;prefs.edit().putBoolean("paused",false).apply();appUpdates.check(true);sync(manual=true)}
      "rollback"->{android.app.AlertDialog.Builder(this@MainActivity).setTitle("恢复内置资源？").setMessage("仅恢复内置模型和光照，保留原始素材。").setNegativeButton("取消",null).setPositiveButton("恢复"){_,_->for(m in listOf("full","mobile")){File(filesDir,"model-"+m+".glb").delete()};getSharedPreferences("native_resource_updates",0).edit().clear().apply();pausedResources=true;prefs.edit().putBoolean("paused",true).apply();loadMode(selected);js("studioDefaults()");status.text="已恢复内置资源，自动资源检测已暂停"}.show()}
     }
    }catch(e:Exception){status.text="操作失败："+e.message}
   }
  }
 }
 private fun loadMode(mode:String) {
  eyeActive=false
  js("window.studioIris&&studioIris(false)")
  regionModel=!diagnostic&&mode=="full"&&cinematic&&refineAtlas
  if(regionModel){
   if(loadAsset("native_full.glb"))return
   regionModel=false
  }
  if(!loadAsset(if(mode=="mobile")"mobile.glb" else "full.glb"))maxPresetPending=false
 }
 private fun toggleIrisTest(){
  if(loading||exportBusy||eyePreparing||diagnostic||!regionModel||viewer.asset==null){Toast.makeText(this,"请先加载高精度分区模型",Toast.LENGTH_SHORT).show();return}
  if(eyeActive){irisLastResult="用户关闭试验";loadMode(selected);return}
  eyePreparing=true
  irisLastResult="正在生成缓存"
  status.text="正在生成虹膜试验模型 · 原始资源不变"
  Thread{
   val result=runCatching{IrisPatch.prepare(StudioAssets.file(this,"native_full.glb"),cacheDir)}
   runOnUiThread{
    eyePreparing=false
    if(isDestroyed||isFinishing||loading||!regionModel||diagnostic||selected!="full")return@runOnUiThread
    result.fold(onSuccess={file->
     eyeActive=true
     if(!load(file)){irisLastResult="试验模型加载失败："+status.text;eyeActive=false;loadMode(selected)}
    },onFailure={e->irisLastResult="缓存生成失败："+e.message;status.text=irisLastResult})
   }
  }.start()
 }
 private fun loadAsset(name:String):Boolean {
  return try {
   val dst=StudioAssets.file(this,name)
   load(dst)
  } catch(e:Exception) { status.text="内置模型加载失败："+e.message;false }
 }
 private fun addStudioLight(x:Float,y:Float,z:Float,power:Float,r:Float,g:Float,b:Float,shadow:Boolean):Int {
  val id=EntityManager.get().create()
  val options=LightManager.ShadowOptions().apply{
   mapSize=2048;shadowCascades=1;shadowBulbRadius=.045f;constantBias=.001f;normalBias=.5f
  }
  LightManager.Builder(LightManager.Type.DIRECTIONAL).color(r,g,b).intensity(power).direction(x,y,z).shadowOptions(options).castShadows(shadow).build(viewer.engine,id)
  viewer.scene.addEntity(id)
  return id
 }
 // Render a second view of the actual scene. Never capture or upscale the WebView.
 private fun enableAdvancedMaterials():String{
  if(!regionModel||diagnostic||loading)return "最高画质：分区模型不可用，保留原材质"
  val results=listOf(installSkinShader(),installHairShader(),installClothShader(),installShellShader())
  val count=listOf(sssInstance,hairInstance,clothInstance,shellInstance).count{it!=null}
  modelAudit+="\n最高画质："+results.joinToString("；")
  return "最高画质 · "+count+"/4 高级材质已启用"
 }
 private fun syncAdvancedUI(){
  js("window.studioSSS&&studioSSS("+(sssInstance!=null)+");window.studioHair&&studioHair("+(hairInstance!=null)+");window.studioCloth&&studioCloth("+(clothInstance!=null)+");window.studioShell&&studioShell("+(shellInstance!=null)+")")
 }
 private fun restoreSafeMaterials(){
  if(loading||exportBusy||eyePreparing){Toast.makeText(this,"请先完成当前操作",Toast.LENGTH_SHORT).show();return}
  maxPresetPending=false;advancedMask=0
  if(eyeActive){loadMode(selected);return}
  disableSkinShader();disableHairShader();disableClothShader();disableShellShader()
  syncAdvancedUI()
  status.text="已恢复原 PBR 纹理采样路径，高精度模型及光照保留"
  Toast.makeText(this,status.text,Toast.LENGTH_SHORT).show()
 }
 private fun compareMaterials(){
  if(eyeActive){Toast.makeText(this,"请先关闭虹膜试验，再进行原 PBR 对照",Toast.LENGTH_SHORT).show();return}
  if(!regionModel||loading||diagnostic){Toast.makeText(this,"需要高精度材质分区模型",Toast.LENGTH_SHORT).show();return}
  val mask=(if(sssInstance!=null)1 else 0) or (if(hairInstance!=null)2 else 0) or (if(clothInstance!=null)4 else 0) or (if(shellInstance!=null)8 else 0)
  if(mask!=0){
   advancedMask=mask
   disableSkinShader();disableHairShader();disableClothShader();disableShellShader()
   status.text="对照：四套自定义材质已关闭，光照和构图不变"
  }else{
   if(advancedMask==0){Toast.makeText(this,"请先逐个开启已修正 UV 的高级材质进行验证",Toast.LENGTH_LONG).show();return}
   val restore=advancedMask
   if(restore and 1!=0)installSkinShader()
   if(restore and 2!=0)installHairShader()
   if(restore and 4!=0)installClothShader()
   if(restore and 8!=0)installShellShader()
   val n=listOf(sssInstance,hairInstance,clothInstance,shellInstance).count{it!=null}
   status.text="对照：高级材质已恢复 "+n+" 套"
  }
  syncAdvancedUI()
 }
 private fun portraitPreset(){
  if(eyeActive){Toast.makeText(this,"请先关闭虹膜反射试验，再进行原 PBR 肖像对照",Toast.LENGTH_LONG).show();return}
  if(loading||exportBusy||diagnostic||!regionModel||viewer.asset==null){
   Toast.makeText(this,"请先恢复正常高精度分区模型，再启用肖像精修",Toast.LENGTH_LONG).show();return
  }
  val labels=arrayOf("A · 仅肖像布光（原 PBR）","B · 皮肤散射","C · 头发反射","D · 织物细节","E · 机械清漆","F · 四套高级材质（联合试验）")
  val masks=intArrayOf(0,1,2,4,8,15)
  android.app.AlertDialog.Builder(this).setTitle("肖像精修 · 单项对照").setItems(labels){_,i->
   if(loading||exportBusy||diagnostic||!regionModel||viewer.asset==null)return@setItems
   maxPresetPending=false;advancedMask=0
   disableSkinShader();disableHairShader();disableClothShader();disableShellShader()
   lightProfile=3
   lighting(exp,if(flat)0f else keyPower,if(flat)2f else ambientPower)
   js("window.studioLightProfile&&studioLightProfile(3)")
   val mask=masks[i]
   val results=mutableListOf<String>()
   if(mask and 1!=0)results.add(installSkinShader())
   if(mask and 2!=0)results.add(installHairShader())
   if(mask and 4!=0)results.add(installClothShader())
   if(mask and 8!=0)results.add(installShellShader())
   val actual=(if(sssInstance!=null)1 else 0) or (if(hairInstance!=null)2 else 0) or (if(clothInstance!=null)4 else 0) or (if(shellInstance!=null)8 else 0)
   syncAdvancedUI()
   val report=if(actual==mask)labels[i] else labels[i]+" · 部分材质启用失败"
   modelAudit+="\n肖像对照：请求 "+mask+" · 实际 "+actual+" · "+results.joinToString("；")
   status.text=report
   Toast.makeText(this,report,Toast.LENGTH_SHORT).show()
  }.setNegativeButton("取消",null).show()
 }
 private fun chooseLightProfile(){
  val labels=arrayOf("电影三点布光 · 标准","柔和棚拍 · 提升补光","轮廓造型 · 减弱补光、增强轮廓","角色肖像 · 正面补光、柔和轮廓")
  android.app.AlertDialog.Builder(this).setTitle("灯光校准").setSingleChoiceItems(labels,lightProfile){dialog,i->
   lightProfile=i;dialog.dismiss()
   lighting(exp,if(flat)0f else keyPower,if(flat)2f else ambientPower)
   status.text=labels[i]
   js("window.studioLightProfile&&studioLightProfile("+i+")")
  }.setNegativeButton("取消",null).show()
 }
 private fun toggleUvProbe(){
  if(!diagnostic||loading||viewer.asset==null){
   Toast.makeText(this,"请先进入纹理诊断 → 仅色彩图诊断",Toast.LENGTH_LONG).show();return
  }
  val rm=viewer.engine.renderableManager
  fun restore(){
   for(b in uvProbeBindings){val ri=rm.getInstance(b.entity);if(ri!=0)rm.setMaterialInstanceAt(ri,b.primitive,b.original)}
   uvProbeBindings.clear()
   uvProbeInstance?.let{viewer.engine.destroyMaterialInstance(it)};uvProbeInstance=null
  }
  if(uvProbeInstance!=null){
   restore();status.text="UV 对照 A · 原 glTF 色彩图";js("window.studioUvProbe&&studioUvProbe(false)");return
  }
  var created:MaterialInstance?=null
  try{
   val asset=viewer.asset?:error("模型未加载")
   val material=uvProbeShader?:run{
    val bytes=resources.openRawResource(R.raw.studio_uv_probe).use{it.readBytes()}
    val buffer=ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder());buffer.put(bytes);buffer.flip()
    Material.Builder().payload(buffer,bytes.size).build(viewer.engine).also{uvProbeShader=it}
   }
   val eligible=mutableListOf<SkinBinding>()
   for(e in asset.entities){
    val ri=rm.getInstance(e);if(ri==0)continue
    for(i in 0 until rm.getPrimitiveCount(ri)){
     require(rm.getEnabledAttributesAt(ri,i).containsAll(material.requiredAttributes)){"诊断 UV 顶点属性不兼容"}
     eligible.add(SkinBinding(e,i,rm.getMaterialInstanceAt(ri,i)))
    }
   }
   require(eligible.isNotEmpty())
   val mi=material.createInstance("Studio_UV_Probe");created=mi
   val sampler=TextureSampler(TextureSampler.MinFilter.LINEAR_MIPMAP_LINEAR,TextureSampler.MagFilter.LINEAR,TextureSampler.WrapMode.REPEAT)
   sampler.setAnisotropy(8f)
   mi.setParameter("baseColorMap",boundAtlas["baseColorMap"]?:error("缺少原始色彩图"),sampler)
   for(b in eligible){uvProbeBindings.add(b);rm.setMaterialInstanceAt(rm.getInstance(b.entity),b.primitive,mi)}
   uvProbeInstance=mi
   status.text="UV 对照 B · 自定义采样器（flipUV=false）"
   js("window.studioUvProbe&&studioUvProbe(true)")
  }catch(e:Exception){
   restore();created?.let{viewer.engine.destroyMaterialInstance(it)}
   status.text="UV 对照未启用："+e.message
   js("window.studioUvProbe&&studioUvProbe(false)")
  }
 }
 // Compare two actual GPU renders, same model, camera, atlas, output and unlit shading.
 // Do not compare background pixels or claim a pass on an empty readback.
 private fun runUvComparison(){
  if(!diagnostic||loading||exportBusy||viewer.asset==null){Toast.makeText(this,"请先进入仅色彩图诊断",Toast.LENGTH_LONG).show();return}
  val vp=viewer.view.viewport
  if(vp.width<=0||vp.height<=0)return
  val w=if(vp.width>=vp.height)1024 else (1024.0*vp.width/vp.height).toInt().coerceAtLeast(1)
  val h=if(vp.height>=vp.width)1024 else (1024.0*vp.height/vp.width).toInt().coerceAtLeast(1)
  val engine=viewer.engine
  var color:Texture?=null;var depth:Texture?=null;var target:RenderTarget?=null;var view:com.google.android.filament.View?=null
  var done=false
  val a=ByteBuffer.allocateDirect(w*h*4);val b=ByteBuffer.allocateDirect(w*h*4)
  fun finish(report:String){
   if(done)return
   done=true
   if(uvProbeInstance!=null)toggleUvProbe()
   view?.let{it.setRenderTarget(null);it.setScene(null);it.setCamera(null);engine.destroyView(it)}
   target?.let{engine.destroyRenderTarget(it)};depth?.let{engine.destroyTexture(it)};color?.let{engine.destroyTexture(it)}
   exportBusy=false;uvResult=report
   js("window.studioExportLock&&studioExportLock(false)")
   if(!isDestroyed){status.text=report;android.app.AlertDialog.Builder(this).setTitle("UV 自动回归检测").setMessage(report).setPositiveButton("关闭",null).show()}
  }
  exportBusy=true
  if(uvProbeInstance!=null)toggleUvProbe()
  js("window.studioExportLock&&studioExportLock(true)")
  status.text="UV 自动检测：正在读取 A/B 两帧"
  try{
   val c=Texture.Builder().width(w).height(h).levels(1).sampler(Texture.Sampler.SAMPLER_2D).format(Texture.InternalFormat.RGBA8).usage(Texture.Usage.COLOR_ATTACHMENT or Texture.Usage.SAMPLEABLE or Texture.Usage.BLIT_SRC).build(engine)
   color=c
   val d=Texture.Builder().width(w).height(h).levels(1).sampler(Texture.Sampler.SAMPLER_2D).format(Texture.InternalFormat.DEPTH24).usage(Texture.Usage.DEPTH_ATTACHMENT).build(engine)
   depth=d
   val rt=RenderTarget.Builder().texture(RenderTarget.AttachmentPoint.COLOR,c).texture(RenderTarget.AttachmentPoint.DEPTH,d).build(engine)
   target=rt
   val off=engine.createView();view=off
   off.setScene(viewer.scene);off.setCamera(viewer.camera);off.setRenderTarget(rt);off.setViewport(Viewport(0,0,w,h))
   off.setPostProcessingEnabled(false);off.setShadowingEnabled(false)
   off.setDynamicResolutionOptions(com.google.android.filament.View.DynamicResolutionOptions().apply{enabled=false})
   off.setMultiSampleAntiAliasingOptions(com.google.android.filament.View.MultiSampleAntiAliasingOptions().apply{enabled=false;sampleCount=1})
   val handler=android.os.Handler(mainLooper)
   fun capture(data:ByteBuffer,callback:Runnable){
    viewer.renderer.renderStandaloneView(off)
    viewer.renderer.readPixels(rt,0,0,w,h,Texture.PixelBufferDescriptor(data,Texture.Format.RGBA,Texture.Type.UBYTE,1,0,0,0,handler,callback))
    engine.flush()
   }
   capture(a,Runnable{
    if(isDestroyed||!active){finish("检测中断：APP 已离开前台");return@Runnable}
    try{
     toggleUvProbe()
     require(uvProbeInstance!=null){"自定义采样器未启用"}
     capture(b,Runnable{
      if(isDestroyed||!active){finish("检测中断：APP 已离开前台");return@Runnable}
      try{
       var foreground=0;var visibleA=0;var visibleB=0;var bad=0;var total=0L
       for(i in 0 until w*h){
        val k=i*4
        val ar=a.get(k).toInt() and 255;val ag=a.get(k+1).toInt() and 255;val ab=a.get(k+2).toInt() and 255
        val br=b.get(k).toInt() and 255;val bg=b.get(k+1).toInt() and 255;val bb=b.get(k+2).toInt() and 255
        val av=maxOf(ar,ag,ab)>8;val bv=maxOf(br,bg,bb)>8
        if(av)visibleA++;if(bv)visibleB++
        if(!av&&!bv)continue
        foreground++
        val dr=kotlin.math.abs(ar-br);val dg=kotlin.math.abs(ag-bg);val db=kotlin.math.abs(ab-bb)
        total+=dr+dg+db
        if(maxOf(dr,dg,db)>12)bad++
       }
       val minVisible=maxOf(256,w*h/100)
       require(visibleA>=minVisible&&visibleB>=minVisible){"有效模型像素不足：请缩放至画面中央后重试"}
       val mean=total.toDouble()/(foreground*3.0)
       val ratio=bad.toDouble()/foreground
       val passed=mean<=2.0&&ratio<=.01
       val fmt=java.util.Locale.US
       val report=(if(passed)"UV A/B 一致性通过" else "UV A/B 存在明显差异")+"\n"+
        "分辨率："+w+"×"+h+"；参与比较像素："+foreground+"\n"+
        "平均通道绝对差："+String.format(fmt,"%.3f",mean)+"/255\n"+
        "差异超过 12 的像素："+String.format(fmt,"%.2f%%",ratio*100)+"\n"+
        "通过阈值：平均差≤2，明显差异≤1%。\n"+
        "仅验证当前视角下原 glTF 与修正采样器一致性，不等于全部材质或全部 UV 已验收。\n已恢复 A 原材质。"
       finish(report)
      }catch(e:Exception){finish("检测无法完成："+e.message)}
     })
    }catch(e:Exception){finish("检测无法完成："+e.message)}
   })
  }catch(e:Exception){finish("检测无法完成："+e.message)}
 }
 private fun showRenderAudit(){
  val vp=viewer.view.viewport
  val n=listOf(sssInstance,hairInstance,clothInstance,shellInstance).count{it!=null}
  val report="实时渲染尺寸："+vp.width+"×"+vp.height+"\n"+
   "模型："+selected+"；独立分区："+regionModel+"\n"+
   "高级材质："+n+"/4；动态分辨率：关闭\n"+
   "最近 UV 检测："+uvResult+"\n"+
   "虹膜试验："+(if(eyePreparing)"准备中" else if(eyeActive&&loading)"加载中" else if(eyeActive&&irisBoundSlots>0)"已绑定" else "关闭")+"；最近结果："+irisLastResult+"\n"+
   "四套高级材质已统一 glTF UV 方向（flipUV=false），需逐项真机验证。虹膜候选面仅 69 个，眼球尚未独立重建。\n"+
   "标准 PNG 共用实时光影配置；离屏抗锯齿与超大尺寸 AO 仍有区别。\n"+
   "16-bit PNG 使用独立线性浮点回读及色调映射，实际精度依赖 GPU。\n\n"+modelAudit
  android.app.AlertDialog.Builder(this).setTitle("渲染诊断 · V6.0").setMessage(report)
   .setNegativeButton("关闭",null).setPositiveButton("复制报告"){_,_->
    val cm=getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
    cm.setPrimaryClip(android.content.ClipData.newPlainText("Starling V6.0",report))
    Toast.makeText(this,"诊断报告已复制",Toast.LENGTH_SHORT).show()
   }.show()
 }
 private fun maximumPreset(){
  if(exportBusy||loading){Toast.makeText(this,"请先完成当前操作",Toast.LENGTH_SHORT).show();return}
  val reload=!regionModel||selected!="full"||!cinematic||!refineAtlas||diagnostic
  cinematic=true;refineAtlas=true;diagnostic=false;selected="full";qualityLevel=2.0;flat=false
  exp=1.04f;keyPower=1f;ambientPower=1f;lightProfile=0
  prefs.edit().putBoolean("cinematic",true).putBoolean("refineAtlas",true).putString("model","full").apply()
  js("window.studioMaximum&&studioMaximum()")
  applyStudioLook()
  if(reload){maxPresetPending=true;loadMode("full")}
  else{restoreSafeMaterials();status.text="最高画质 · 原 PBR 安全模式；请逐项测试高级材质"}
 }
 private fun chooseExport(){
  if(exportBusy||loading||viewer.asset==null||diagnostic){Toast.makeText(this,"请先完成正常模型加载",Toast.LENGTH_SHORT).show();return}
  val labels=arrayOf("2K · 长边 2560","4K · 长边 3840","8K · 长边 7680（高内存）")
  android.app.AlertDialog.Builder(this).setTitle("超高清模型渲染输出").setItems(labels){_,i->
   val edge=intArrayOf(2560,3840,7680)[i]
   android.app.AlertDialog.Builder(this).setTitle("选择输出色深").setItems(arrayOf("标准 PNG · 每通道 8-bit · 保持影视后期","高色深 PNG · 每通道 16-bit · 独立色调映射")){_,fmt->exportScene(edge,fmt==1)}.setNegativeButton("取消",null).show()
  }.setNegativeButton("取消",null).show()
 }
 private fun exportScene(longEdge:Int,highDepth:Boolean){
  if(exportBusy||loading||viewer.asset==null||diagnostic)return
  if(android.os.Build.VERSION.SDK_INT<29){Toast.makeText(this,"相册导出需要 Android 10 或以上",Toast.LENGTH_LONG).show();return}
  val vp=viewer.view.viewport
  if(vp.width<=0||vp.height<=0)return
  val w=if(vp.width>=vp.height)longEdge else ((longEdge.toDouble()*vp.width/vp.height).toInt().coerceAtLeast(2)/2)*2
  val h=if(vp.height>=vp.width)longEdge else ((longEdge.toDouble()*vp.height/vp.width).toInt().coerceAtLeast(2)/2)*2
  val pixels=w.toLong()*h
  val am=getSystemService(ACTIVITY_SERVICE) as android.app.ActivityManager
  val mem=android.app.ActivityManager.MemoryInfo();am.getMemoryInfo(mem)
  // Conservative allowance for HDR, depth, AO, resolved color, readback and PNG bitmap.
  val estimate=pixels*(if(highDepth)96L else if(longEdge<=3840)72L else 48L)+256L*1024*1024
  if(mem.lowMemory||mem.availMem-mem.threshold<estimate){
   Toast.makeText(this,"可用内存不足，未降低分辨率。请选择较低规格。",Toast.LENGTH_LONG).show();return
  }
  exportBusy=true
  js("window.studioExportLock&&studioExportLock(true)")
  status.text="准备离屏渲染 "+w+"×"+h
  Toast.makeText(this,status.text,Toast.LENGTH_SHORT).show()
  // Probe actual GLES framebuffer dimensions on a temporary, non-shared context.
  // Filament owns the display; do not eglTerminate it here.
  Thread{
   val limit=probeRenderLimit(highDepth)
   runOnUiThread{
    if(isDestroyed||!active){exportBusy=false;js("window.studioExportLock&&studioExportLock(false)");return@runOnUiThread}
    if(limit<maxOf(w,h)){
     exportBusy=false;js("window.studioExportLock&&studioExportLock(false)")
     status.text=if(limit<=0)"无法确认 GPU 最大渲染尺寸，未执行导出" else "GPU 最大渲染尺寸 "+limit+"，不支持所选输出"
     Toast.makeText(this,status.text,Toast.LENGTH_LONG).show()
    }else renderExport(w,h,longEdge,highDepth)
   }
  }.start()
 }
 private fun probeRenderLimit(highDepth:Boolean):Int{
  val d=android.opengl.EGL14.eglGetDisplay(android.opengl.EGL14.EGL_DEFAULT_DISPLAY)
  if(d==android.opengl.EGL14.EGL_NO_DISPLAY)return 0
  var c=android.opengl.EGL14.EGL_NO_CONTEXT
  var p=android.opengl.EGL14.EGL_NO_SURFACE
  try{
   val version=IntArray(2)
   if(!android.opengl.EGL14.eglInitialize(d,version,0,version,1))return 0
   val attrs=intArrayOf(android.opengl.EGL14.EGL_SURFACE_TYPE,android.opengl.EGL14.EGL_PBUFFER_BIT,
    android.opengl.EGL14.EGL_RENDERABLE_TYPE,0x40,android.opengl.EGL14.EGL_RED_SIZE,8,
    android.opengl.EGL14.EGL_GREEN_SIZE,8,android.opengl.EGL14.EGL_BLUE_SIZE,8,android.opengl.EGL14.EGL_NONE)
   val configs=arrayOfNulls<android.opengl.EGLConfig>(1);val count=IntArray(1)
   if(!android.opengl.EGL14.eglChooseConfig(d,attrs,0,configs,0,1,count,0)||count[0]==0)return 0
   val config=configs[0]?:return 0
   c=android.opengl.EGL14.eglCreateContext(d,config,android.opengl.EGL14.EGL_NO_CONTEXT,intArrayOf(android.opengl.EGL14.EGL_CONTEXT_CLIENT_VERSION,3,android.opengl.EGL14.EGL_NONE),0)
   if(c==android.opengl.EGL14.EGL_NO_CONTEXT)return 0
   p=android.opengl.EGL14.eglCreatePbufferSurface(d,config,intArrayOf(android.opengl.EGL14.EGL_WIDTH,1,android.opengl.EGL14.EGL_HEIGHT,1,android.opengl.EGL14.EGL_NONE),0)
   if(p==android.opengl.EGL14.EGL_NO_SURFACE||!android.opengl.EGL14.eglMakeCurrent(d,p,p,c))return 0
   val tex=IntArray(1);val rb=IntArray(1);val viewport=IntArray(2)
   android.opengl.GLES30.glGetIntegerv(android.opengl.GLES30.GL_MAX_TEXTURE_SIZE,tex,0)
   android.opengl.GLES30.glGetIntegerv(android.opengl.GLES30.GL_MAX_RENDERBUFFER_SIZE,rb,0)
   android.opengl.GLES30.glGetIntegerv(android.opengl.GLES30.GL_MAX_VIEWPORT_DIMS,viewport,0)
   if(highDepth){
    val texture=IntArray(1);val framebuffer=IntArray(1)
    android.opengl.GLES30.glGenTextures(1,texture,0)
    android.opengl.GLES30.glGenFramebuffers(1,framebuffer,0)
    try{
     android.opengl.GLES30.glBindTexture(android.opengl.GLES30.GL_TEXTURE_2D,texture[0])
     android.opengl.GLES30.glTexImage2D(android.opengl.GLES30.GL_TEXTURE_2D,0,android.opengl.GLES30.GL_RGBA16F,1,1,0,android.opengl.GLES30.GL_RGBA,android.opengl.GLES30.GL_HALF_FLOAT,null)
     android.opengl.GLES30.glBindFramebuffer(android.opengl.GLES30.GL_FRAMEBUFFER,framebuffer[0])
     android.opengl.GLES30.glFramebufferTexture2D(android.opengl.GLES30.GL_FRAMEBUFFER,android.opengl.GLES30.GL_COLOR_ATTACHMENT0,android.opengl.GLES30.GL_TEXTURE_2D,texture[0],0)
     if(android.opengl.GLES30.glCheckFramebufferStatus(android.opengl.GLES30.GL_FRAMEBUFFER)!=android.opengl.GLES30.GL_FRAMEBUFFER_COMPLETE)return 0
     android.opengl.GLES30.glClearColor(.1234f,.4321f,.731f,1f)
     android.opengl.GLES30.glClear(android.opengl.GLES30.GL_COLOR_BUFFER_BIT)
     val sample=ByteBuffer.allocateDirect(16).order(ByteOrder.nativeOrder()).asFloatBuffer()
     android.opengl.GLES30.glReadPixels(0,0,1,1,android.opengl.GLES30.GL_RGBA,android.opengl.GLES30.GL_FLOAT,sample)
     if(android.opengl.GLES30.glGetError()!=android.opengl.GLES30.GL_NO_ERROR||kotlin.math.abs(sample.get(0)-.1234f)>.0005f||kotlin.math.abs(sample.get(1)-.4321f)>.0005f)return 0
    }finally{
     android.opengl.GLES30.glBindFramebuffer(android.opengl.GLES30.GL_FRAMEBUFFER,0)
     android.opengl.GLES30.glDeleteFramebuffers(1,framebuffer,0);android.opengl.GLES30.glDeleteTextures(1,texture,0)
    }
   }
   return minOf(tex[0],rb[0],viewport[0],viewport[1])
  }catch(e:Exception){return 0}
  finally{
   android.opengl.EGL14.eglMakeCurrent(d,android.opengl.EGL14.EGL_NO_SURFACE,android.opengl.EGL14.EGL_NO_SURFACE,android.opengl.EGL14.EGL_NO_CONTEXT)
   if(p!=android.opengl.EGL14.EGL_NO_SURFACE)android.opengl.EGL14.eglDestroySurface(d,p)
   if(c!=android.opengl.EGL14.EGL_NO_CONTEXT)android.opengl.EGL14.eglDestroyContext(d,c)
   android.opengl.EGL14.eglReleaseThread()
  }
 }
 private fun renderExport(w:Int,h:Int,longEdge:Int,highDepth:Boolean){
  val engine=viewer.engine
  var color:Texture?=null;var depth:Texture?=null;var target:RenderTarget?=null
  var v:com.google.android.filament.View?=null
  var released=false
  fun release(){
   if(released)return
   released=true
   v?.let{it.setRenderTarget(null);it.setScene(null);it.setCamera(null);engine.destroyView(it)}
   target?.let{engine.destroyRenderTarget(it)}
   depth?.let{engine.destroyTexture(it)}
   color?.let{engine.destroyTexture(it)}
  }
  try{
   require(viewer.asset!=null&&!loading&&!diagnostic)
   val bytes=Math.multiplyExact(Math.multiplyExact(w,h),if(highDepth)16 else 4)
   val data=ByteBuffer.allocateDirect(bytes).order(ByteOrder.LITTLE_ENDIAN)
   val c=Texture.Builder().width(w).height(h).levels(1).sampler(Texture.Sampler.SAMPLER_2D)
    .format(if(highDepth)Texture.InternalFormat.RGBA16F else Texture.InternalFormat.RGBA8).usage(Texture.Usage.COLOR_ATTACHMENT or Texture.Usage.SAMPLEABLE or Texture.Usage.BLIT_SRC).build(engine)
   color=c
   val d=Texture.Builder().width(w).height(h).levels(1).sampler(Texture.Sampler.SAMPLER_2D)
    .format(Texture.InternalFormat.DEPTH24).usage(Texture.Usage.DEPTH_ATTACHMENT).build(engine)
   depth=d
   val rt=RenderTarget.Builder().texture(RenderTarget.AttachmentPoint.COLOR,c).texture(RenderTarget.AttachmentPoint.DEPTH,d).build(engine)
   target=rt
   val off=engine.createView();v=off
   off.setScene(viewer.scene);off.setCamera(viewer.camera);off.setRenderTarget(rt)
   off.setViewport(Viewport(0,0,w,h))
   configureLook(off,cinematic&&!diagnostic,true,longEdge,highDepth)
   status.text="离屏渲染 "+w+"×"+h
   viewer.renderer.renderStandaloneView(off)
   val handler=android.os.Handler(mainLooper)
   val descriptor=Texture.PixelBufferDescriptor(data,Texture.Format.RGBA,if(highDepth)Texture.Type.FLOAT else Texture.Type.UBYTE,1,0,0,0,handler,Runnable{
    release()
    if(isDestroyed){exportBusy=false;js("window.studioExportLock&&studioExportLock(false)");return@Runnable}
    Thread{
     try{
      if(highDepth){saveHighDepth(data,w,h);runOnUiThread{exportBusy=false;js("window.studioExportLock&&studioExportLock(false)");status.text="已保存 "+w+"×"+h+" 64-bit PNG";Toast.makeText(this,status.text,Toast.LENGTH_LONG).show()};return@Thread}
      val bitmap=android.graphics.Bitmap.createBitmap(w,h,android.graphics.Bitmap.Config.ARGB_8888)
      try{
       val row=IntArray(w);val rgba=data.asIntBuffer();var hasColor=false
       for(y in 0 until h){
        rgba.position(y*w);rgba.get(row,0,w)
        for(x in 0 until w){val q=row[x];if((q and 0xffffff)!=0)hasColor=true;row[x]=0xff000000.toInt() or ((q and 255) shl 16) or (q and 0xff00) or ((q ushr 16) and 255)}
        bitmap.setPixels(row,0,w,0,y,w,1)
       }
       require(hasColor){"GPU 回读为空，未保存"}
       val fileName="Starling_"+w+"x"+h+"_"+System.currentTimeMillis()+".png"
       val values=android.content.ContentValues().apply{
        put(android.provider.MediaStore.Images.Media.DISPLAY_NAME,fileName)
        put(android.provider.MediaStore.Images.Media.MIME_TYPE,"image/png")
        put(android.provider.MediaStore.Images.Media.RELATIVE_PATH,"Pictures/Starling")
        put(android.provider.MediaStore.Images.Media.IS_PENDING,1)
       }
       val uri=contentResolver.insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI,values)?:error("无法创建相册文件")
       try{
        contentResolver.openOutputStream(uri,"w")!!.use{require(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it))}
        values.clear();values.put(android.provider.MediaStore.Images.Media.IS_PENDING,0);contentResolver.update(uri,values,null,null)
       }catch(e:Throwable){contentResolver.delete(uri,null,null);throw e}
       runOnUiThread{exportBusy=false;js("window.studioExportLock&&studioExportLock(false)");status.text="已保存 "+w+"×"+h+" PNG";Toast.makeText(this,"已保存到相册 / Starling",Toast.LENGTH_LONG).show()}
      }finally{bitmap.recycle()}
     }catch(e:Throwable){runOnUiThread{exportBusy=false;js("window.studioExportLock&&studioExportLock(false)");status.text="输出失败："+e.message;Toast.makeText(this,status.text,Toast.LENGTH_LONG).show()}}
    }.start()
   })
   viewer.renderer.readPixels(rt,0,0,w,h,descriptor)
   engine.flush()
  }catch(e:Throwable){
   release();exportBusy=false;js("window.studioExportLock&&studioExportLock(false)");status.text="离屏渲染失败："+e.message;Toast.makeText(this,status.text,Toast.LENGTH_LONG).show()
  }
 }
 // PNG color type 6, depth 16. Stream filtered rows through zlib and bounded IDAT chunks.
 // Input is actual float readback from RGBA16F; no expansion from an 8-bit screenshot.
 private fun saveHighDepth(data:ByteBuffer,w:Int,h:Int){
  val rgba=data.order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
  var valid=false
  for(i in 0 until w*h){val r=rgba.get(i*4);val g=rgba.get(i*4+1);val b=rgba.get(i*4+2);if(r.isFinite()&&g.isFinite()&&b.isFinite()&&maxOf(r,g,b)>.00001f){valid=true;break}}
  require(valid){"高色深 GPU 回读为空，未保存"}
  val values=android.content.ContentValues().apply{
   put(android.provider.MediaStore.Images.Media.DISPLAY_NAME,"Starling_"+w+"x"+h+"_RGBA16_"+System.currentTimeMillis()+".png")
   put(android.provider.MediaStore.Images.Media.MIME_TYPE,"image/png")
   put(android.provider.MediaStore.Images.Media.RELATIVE_PATH,"Pictures/Starling")
   put(android.provider.MediaStore.Images.Media.IS_PENDING,1)
  }
  val uri=contentResolver.insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI,values)?:error("无法创建相册文件")
  try{
   contentResolver.openOutputStream(uri,"w")!!.use{raw->
    val out=java.io.DataOutputStream(java.io.BufferedOutputStream(raw))
    fun chunk(type:String,payload:ByteArray,n:Int=payload.size){
     val tag=type.toByteArray(Charsets.US_ASCII);val crc=java.util.zip.CRC32()
     crc.update(tag);crc.update(payload,0,n)
     out.writeInt(n);out.write(tag);out.write(payload,0,n);out.writeInt(crc.value.toInt())
    }
    out.write(byteArrayOf(137.toByte(),80,78,71,13,10,26,10))
    val header=ByteBuffer.allocate(13).order(ByteOrder.BIG_ENDIAN).putInt(w).putInt(h).put(16.toByte()).put(6.toByte()).put(0.toByte()).put(0.toByte()).put(0.toByte()).array()
    chunk("IHDR",header);chunk("sRGB",byteArrayOf(0))
    val row=ByteArray(1+w*8);val compressed=ByteArray(65536);val z=java.util.zip.Deflater(6)
    // Monotonic filmic curve followed by sRGB transfer, independent of preview grading.
    fun quant(v:Float):Int{
     val x=if(v.isFinite())v.toDouble().coerceIn(0.0,65504.0)else 0.0
     val y=((x*(2.51*x+.03))/(x*(2.43*x+.59)+.14)).coerceIn(0.0,1.0)
     val srgb=if(y<=.0031308)12.92*y else 1.055*Math.pow(y,1.0/2.4)-.055
     return (srgb*65535.0+.5).toInt().coerceIn(0,65535)
    }
    try{
     for(y in 0 until h){
      row[0]=1
      for(x in 0 until w){
       val k=(y*w+x)*4;val o=1+x*8
       for(c in 0..3){val q=if(c==3)65535 else quant(rgba.get(k+c));row[o+2*c]=(q ushr 8).toByte();row[o+2*c+1]=q.toByte()}
      }
      // PNG Sub filter, computed backwards to preserve original preceding pixel.
      for(i in row.lastIndex downTo 9)row[i]=(row[i].toInt()-row[i-8].toInt()).toByte()
      z.setInput(row)
      while(!z.needsInput()){val n=z.deflate(compressed);if(n>0)chunk("IDAT",compressed,n)}
     }
     z.finish();while(!z.finished()){val n=z.deflate(compressed);if(n>0)chunk("IDAT",compressed,n)}
    }finally{z.end()}
    chunk("IEND",ByteArray(0));out.flush()
   }
   values.clear();values.put(android.provider.MediaStore.Images.Media.IS_PENDING,0);contentResolver.update(uri,values,null,null)
  }catch(e:Throwable){contentResolver.delete(uri,null,null);throw e}
 }
 // Shared optical settings; only frame-history AA and very large export AO differ.
 private fun configureLook(v:com.google.android.filament.View,quality:Boolean,export:Boolean=false,longEdge:Int=0,highDepth:Boolean=false){
  v.setPostProcessingEnabled(!highDepth)
  v.setColorGrading(if(quality)cinematicGrading else neutralGrading)
  v.setDynamicResolutionOptions(com.google.android.filament.View.DynamicResolutionOptions().apply{enabled=false})
  v.setShadowingEnabled(quality)
  v.setShadowType(if(quality)com.google.android.filament.View.ShadowType.PCSS else com.google.android.filament.View.ShadowType.PCF)
  v.setSoftShadowOptions(com.google.android.filament.View.SoftShadowOptions().apply{penumbraScale=1.2f;penumbraRatioScale=1f})
  v.setAmbientOcclusionOptions(com.google.android.filament.View.AmbientOcclusionOptions().apply{
   enabled=quality&&!highDepth&&qualityLevel>=1.0
   radius=.035f;intensity=.35f;power=1f
   resolution=if(qualityLevel>=2&&(!export||longEdge<=3840))1f else .5f
   this.quality=com.google.android.filament.View.QualityLevel.HIGH
   lowPassFilter=com.google.android.filament.View.QualityLevel.HIGH
   upsampling=com.google.android.filament.View.QualityLevel.HIGH
  })
  v.setTemporalAntiAliasingOptions(com.google.android.filament.View.TemporalAntiAliasingOptions().apply{
   enabled=quality&&!export&&!highDepth;feedback=.18f;filterWidth=.9f;lodBias=-.5f
   sharpness=.18f;upscaling=false;preventFlickering=true
  })
  v.antiAliasing=if(highDepth||quality&&!export)com.google.android.filament.View.AntiAliasing.NONE else com.google.android.filament.View.AntiAliasing.FXAA
  v.setRenderQuality(com.google.android.filament.View.RenderQuality().apply{hdrColorBuffer=com.google.android.filament.View.QualityLevel.ULTRA})
  v.setDithering(com.google.android.filament.View.Dithering.NONE)
  v.setMultiSampleAntiAliasingOptions(com.google.android.filament.View.MultiSampleAntiAliasingOptions().apply{
   enabled=!highDepth&&qualityLevel>1&&(!export||longEdge<=3840)
   sampleCount=if(enabled)4 else 1
  })
 }
 private fun applyStudioLook(){
  val quality=cinematic&&!diagnostic
  configureLook(viewer.view,quality)
  val lm=viewer.engine.lightManager
  if(mainLamp!=0)lm.setShadowCaster(lm.getInstance(mainLamp),quality)
  val rm=viewer.engine.renderableManager
  viewer.asset?.entities?.forEach{entity->
   val ri=rm.getInstance(entity)
   if(ri!=0){rm.setCastShadows(ri,quality);rm.setReceiveShadows(ri,quality)}
  }
  lighting(exp,if(flat)0f else keyPower,if(flat)2f else ambientPower)
 }

 private fun lighting(e:Float,k:Float,a:Float) {
  viewer.camera.setExposure(16f,1f/100f,100f*e)
  val lm=viewer.engine.lightManager
  // Portrait: redistribute light rather than raising global exposure.
  if(mainLamp!=0){
   val mi=lm.getInstance(mainLamp)
   if(lightProfile==3&&!flat)lm.setDirection(mi,.38f,-.43f,-.82f)else lm.setDirection(mi,.58f,-.58f,-.58f)
   lm.setIntensity(mi,(if(cinematic)46000f else 38000f)*k*(if(lightProfile==3&&!flat).84f else 1f))
  }
  val fillRatio=when(lightProfile){1->1.30f;2->.65f;3->1.65f;else->1f}
  val rimRatio=when(lightProfile){1->.72f;2->1.25f;3->.72f;else->1f}
  if(fillLamp!=0){
   val fi=lm.getInstance(fillLamp)
   if(lightProfile==3)lm.setDirection(fi,-.22f,-.08f,-1f)else lm.setDirection(fi,-.6f,-.22f,-.8f)
   lm.setIntensity(fi,(if(cinematic)20000f else 30000f)*(if(flat)0f else fillRatio))
  }
  if(rimLamp!=0)lm.setIntensity(lm.getInstance(rimLamp),(if(cinematic)30000f else 12000f)*(if(flat)0f else rimRatio))
  setEnvironment(a,if(flat)0f else reflectPower)
 }
 private fun load(f:File):Boolean {
  try {
   val n=f.length(); require(n in 20L..150_000_000L)
   val b=ByteBuffer.allocateDirect(n.toInt()).order(ByteOrder.LITTLE_ENDIAN)
   f.inputStream().channel.use { ch -> while(b.hasRemaining()) { if(ch.read(b)<0) error("文件不完整") } }
   b.flip(); require(b.getInt(0)==0x46546c67); require(b.getInt(4)==2); require(b.getInt(8)==n.toInt())
   val jsonSize=b.getInt(12);require(jsonSize in 2..4_000_000&&jsonSize%4==0&&20+jsonSize+8<=b.limit());require(b.getInt(16)==0x4e4f534a)
   val jsonBytes=ByteArray(jsonSize);b.position(20);b.get(jsonBytes)
   val doc=JSONObject(String(jsonBytes,Charsets.UTF_8).trim())
   val materials=doc.optJSONArray("materials")?:error("缺少材质")
   val images=doc.optJSONArray("images")?:error("缺少纹理")
   val textures=doc.optJSONArray("textures")?:error("缺少纹理绑定")
   var bindings=0
   for(i in 0 until materials.length()){
    val mat=materials.getJSONObject(i)
    val p=mat.optJSONObject("pbrMetallicRoughness")?:continue
    val index=p.optJSONObject("baseColorTexture")?.optInt("index",-1)?:-1
    if(index>=0){require(index<textures.length());val source=textures.getJSONObject(index).getInt("source");require(source in 0 until images.length());bindings++}
   }
   require(bindings>0){"未找到有效色彩图绑定"}
   modelAudit="文件："+f.name+"\n材质："+materials.length()+" · 图像："+images.length()+" · 色彩图绑定："+bindings
   // Only share a GPU atlas across slots when all their texture references match.
   val mat=materials.getJSONObject(0)
   val pbr=mat.getJSONObject("pbrMetallicRoughness")
   val expectedNames=setOf("General","Skin_candidate","Hair_candidate","Blue_fabric_candidate","Painted_shell_candidate","Metal_candidate")
   if(regionModel){
    val expected=if(eyeActive)expectedNames+setOf("Iris_candidate_General","Iris_candidate_Skin_candidate") else expectedNames
    require(materials.length()==expected.size){"分区模型材质数量不一致"}
    val names=(0 until materials.length()).map{materials.getJSONObject(it).getString("name")}.toSet()
    require(names==expected){"分区模型名称不一致"}
   }else require(materials.length()==1){"非分区模型须使用原始单图集"}
   for(i in 1 until materials.length()){
    val other=materials.getJSONObject(i)
    val op=other.getJSONObject("pbrMetallicRoughness")
    for(key in listOf("baseColorTexture","metallicRoughnessTexture")){
     require(op.optJSONObject(key)?.toString()==pbr.optJSONObject(key)?.toString()){"不同材质图集不可共享："+key}
    }
    val nt=other.optJSONObject("normalTexture")
    val iris=eyeActive&&other.optString("name") in setOf("Iris_candidate_General","Iris_candidate_Skin_candidate")
    if(iris){require(nt?.optInt("index")==mat.getJSONObject("normalTexture").getInt("index")&&nt?.optInt("texCoord",0)==0&&nt?.optDouble("scale")==0.2){"虹膜法线绑定异常"}}
    else require(nt?.toString()==mat.optJSONObject("normalTexture")?.toString()){"法线绑定不一致"}
   }
   val views=doc.getJSONArray("bufferViews")
   val dataStart=28+jsonSize
   val atlas=mutableListOf<Atlas>()
   fun add(parameter:String,ref:JSONObject?,srgb:Boolean){
    if(ref==null)return
    require(ref.optInt("texCoord",0)==0)
    val source=textures.getJSONObject(ref.getInt("index")).getInt("source")
    val view=views.getJSONObject(images.getJSONObject(source).getInt("bufferView"))
    require(view.optInt("buffer",0)==0)
    val offset=dataStart.toLong()+view.optLong("byteOffset",0)
    val len=view.getInt("byteLength")
    require(len in 1..30_000_000 && offset>=dataStart && offset+len<=b.limit())
    val bytes=ByteArray(len);b.duplicate().apply{position(offset.toInt());get(bytes)}
    atlas.add(Atlas(parameter,bytes,srgb))
   }
   add("baseColorMap",pbr.optJSONObject("baseColorTexture"),true)
   if(!diagnostic){add("metallicRoughnessMap",pbr.optJSONObject("metallicRoughnessTexture"),false);add("normalMap",mat.optJSONObject("normalTexture"),false)}
   b.rewind()
   val input=if(diagnostic)diagnosticGlb(b,doc,jsonSize) else b
   viewer.destroyModel()
   clearExplicit()
   pendingAtlas=atlas
   loadBuffer=input
   loading=true;loadStart=android.os.SystemClock.elapsedRealtime();lastLoadPercent=-1
   viewer.loadModelGlb(input);require(viewer.asset!=null){"Filament 无法解析模型"}
   viewer.transformToUnitCube()
   val tm=viewer.engine.transformManager
   baseTransform=tm.getTransform(tm.getInstance(viewer.asset!!.root),FloatArray(16))
   applyTransform();status.text="正在加载模型纹理";js("window.studioProgress&&studioProgress(0)");return true
  } catch(e:Exception) { loading=false;viewer.destroyModel();clearExplicit();loadBuffer=null;status.text="加载失败："+e.message;js("window.studioFailure&&studioFailure("+JSONObject.quote(status.text.toString())+")");return false }
 }
 // Temporary diagnostic copy only. The normal rendering path never changes GLB bytes.
 private fun diagnosticGlb(source:ByteBuffer,doc:JSONObject,jsonSize:Int):ByteBuffer{
  val materials=doc.getJSONArray("materials")
  for(i in 0 until materials.length()){
   val m=materials.getJSONObject(i)
   val original=m.getJSONObject("pbrMetallicRoughness")
   val p=JSONObject().put("baseColorFactor",org.json.JSONArray("[1,1,1,1]"))
   p.put("baseColorTexture",original.getJSONObject("baseColorTexture"))
   m.put("pbrMetallicRoughness",p)
   m.remove("normalTexture");m.remove("occlusionTexture");m.remove("emissiveTexture");m.remove("emissiveFactor")
   m.put("extensions",JSONObject().put("KHR_materials_unlit",JSONObject()))
  }
  val used=doc.optJSONArray("extensionsUsed")?:org.json.JSONArray().also{doc.put("extensionsUsed",it)}
  if((0 until used.length()).none{used.optString(it)=="KHR_materials_unlit"})used.put("KHR_materials_unlit")
  val json=doc.toString().toByteArray(Charsets.UTF_8)
  val padded=(json.size+3)/4*4
  source.position(20+jsonSize)
  val out=ByteBuffer.allocateDirect(20+padded+source.remaining()).order(ByteOrder.LITTLE_ENDIAN)
  out.putInt(0x46546c67);out.putInt(2);out.putInt(out.capacity());out.putInt(padded);out.putInt(0x4e4f534a)
  out.put(json);repeat(padded-json.size){out.put(32.toByte())};out.put(source);out.flip()
  return out
 }
 override fun onActivityResult(requestCode:Int,resultCode:Int,data:Intent?) {
  super.onActivityResult(requestCode,resultCode,data)
  if(requestCode==81){
   val uri=data?.data
   if(resultCode!=RESULT_OK||uri==null){showAssetRecovery("未选择备份");return}
   val progress=android.app.ProgressDialog(this).apply{setTitle("恢复模型");setMessage("正在读取并校验七项原始素材");setCancelable(false);show()}
   Thread{
    try{
     contentResolver.openInputStream(uri)!!.use{StudioAssets.importBackup(this,it)}
     runOnUiThread{if(!isDestroyed){progress.dismiss();prepareStartupAssets()}}
    }catch(e:Exception){runOnUiThread{if(!isDestroyed){progress.dismiss();showAssetRecovery(e.message?:"备份校验失败")}}}
   }.start()
   return
  }
  if(requestCode!=7||resultCode!=RESULT_OK) return
  val uri=data?.data?:return
  status.text="正在读取模型…"
  Thread {
   val tmp=File(filesDir,"incoming.glb")
   try {
    contentResolver.openInputStream(uri)!!.use { input -> tmp.outputStream().use { out ->
     val buf=ByteArray(65536); var count=0L
     while(true) { val n=input.read(buf); if(n<0) break; count+=n; require(count<=150_000_000L); out.write(buf,0,n) }
    } }
    java.io.RandomAccessFile(tmp,"r").use { r -> require(r.length()>=20); require(Integer.reverseBytes(r.readInt())==0x46546c67); require(Integer.reverseBytes(r.readInt())==2); require(Integer.reverseBytes(r.readInt()).toLong()==r.length()) }
    val dst=File(filesDir,"character.glb"); require(tmp.renameTo(dst))
    runOnUiThread { if(!isDestroyed) { selected="imported"; load(dst) } }
   } catch(e:Exception) { tmp.delete(); runOnUiThread { status.text="导入失败："+e.message } }
  }.start()
 }
 private fun sync(approved:String?=null,manual:Boolean=false) {
  if(manual)status.text="保真恢复版：资源更新暂缓，程序更新正常"
 }
 override fun onResume() { super.onResume(); active=true; frames.postFrameCallback(ticker); if(initialized){if(!pausedResources)sync();appUpdates.start()} }
 override fun onPause() { active=false; frames.removeFrameCallback(ticker); appUpdates.stop(); super.onPause() }
}
EOF
mkdir -p app/src/main/res/xml
cat > app/src/main/res/xml/update_paths.xml <<'EOF'
<paths xmlns:android="http://schemas.android.com/apk/res/android"><files-path name="verified_updates" path="updates/"/></paths>
EOF
cat > app/src/main/java/com/starling/filament/AppUpdates.kt <<'EOF'
package com.starling.filament
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.widget.Toast
import androidx.core.content.FileProvider
import java.io.File
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import java.security.MessageDigest
import org.json.JSONObject

class AppUpdates(private val activity:Activity) {
 private val handler=Handler(Looper.getMainLooper())
 private val base="https://raw.githubusercontent.com/xinminyu168-spec/starling-3d-studio/main/"
 private var busy=false
 private var running=false
 private var prompted=0L
 private var dialog:AlertDialog?=null
 private val tick=object:Runnable {
  override fun run(){if(!running)return;check(false);handler.postDelayed(this,30000)}
 }
 fun start(){if(running)return;running=true;handler.post(tick)}
 fun stop(){running=false;handler.removeCallbacks(tick)}
 private fun notify(s:String){Toast.makeText(activity,s,Toast.LENGTH_LONG).show()}
 private fun connect(url:String):HttpsURLConnection{
  val u=URL(url)
  require(u.protocol=="https" && u.userInfo==null && u.port==-1)
  require((u.host=="xinminyu168-spec.github.io" && u.path.startsWith("/starling-3d-studio/"))||(u.host=="raw.githubusercontent.com" && u.path.startsWith("/xinminyu168-spec/starling-3d-studio/main/")))
  return (u.openConnection() as HttpsURLConnection).apply{connectTimeout=15000;readTimeout=30000;instanceFollowRedirects=false;useCaches=false}
 }
 private fun manifest():JSONObject{
  val signer=certs(installed()).singleOrNull()?:error("无法识别应用签名")
  val name=when(signer){
   "065d80ddf51e5a7cbc881900351ee355cdd8aa2447fee0a959d0391ecc02c7ba"->"app-update-v2.json"
   "393da066780f599c8151cbf70a564b72ff3e60f0bcd05aa38fa52f74dd60efe2"->"app-update.json"
   else->error("此安装签名没有正式更新渠道")
  }
  val c=connect(base+name+"?t="+System.currentTimeMillis())
  try{require(c.responseCode==200);return c.inputStream.use{ val out=java.io.ByteArrayOutputStream();val b=ByteArray(4096);while(true){val n=it.read(b);if(n<0)break;require(out.size()+n<=32768);out.write(b,0,n)};JSONObject(out.toString("UTF-8")) }}
  finally{c.disconnect()}
 }
 @Suppress("DEPRECATION")
 private fun version(p:android.content.pm.PackageInfo):Long=if(Build.VERSION.SDK_INT>=28)p.longVersionCode else p.versionCode.toLong()
 @Suppress("DEPRECATION")
 private fun certs(p:android.content.pm.PackageInfo):Set<String>{
  val a=if(Build.VERSION.SDK_INT>=28)p.signingInfo?.apkContentsSigners else p.signatures
  return a?.map{hex(MessageDigest.getInstance("SHA-256").digest(it.toByteArray()))}?.toSet()?:emptySet()
 }
 private fun hex(b:ByteArray)=b.joinToString(""){"%02x".format(it)}
 @Suppress("DEPRECATION")
 private fun installed():android.content.pm.PackageInfo=activity.packageManager.getPackageInfo(activity.packageName,if(Build.VERSION.SDK_INT>=28)PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES)
 @Suppress("DEPRECATION")
 private fun verify(f:File,v:Long){
  val info=activity.packageManager.getPackageArchiveInfo(f.absolutePath,if(Build.VERSION.SDK_INT>=28)PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES)?:error("无效 APK")
  val current=installed()
  require(info.packageName==activity.packageName && version(info)==v && v>version(current)){"版本或包名不匹配"}
  require(certs(info).isNotEmpty() && certs(info)==certs(current)){"签名不匹配"}
 }
 private data class ApprovedUpdate(val version:Long,val hash:String,val size:Long,val url:String)
 fun check(manual:Boolean)=check(manual,null)
 private fun check(manual:Boolean,approved:ApprovedUpdate?){
  if(busy){if(manual)notify("正在检查或下载更新");return}
  busy=true
  if(manual)notify("正在检查程序版本…")
  Thread{
   try{
    val j=manifest()
    require(j.optInt("schema",0)==1){"不支持的更新清单"}
    val signer=certs(installed()).singleOrNull()?:error("无法识别应用签名")
    if(signer=="065d80ddf51e5a7cbc881900351ee355cdd8aa2447fee0a959d0391ecc02c7ba")require(j.optString("certificateSha256","")==signer){"更新渠道签名不匹配"}
    val v=j.optLong("versionCode",0)
    val current=installed()
    if(!j.optBoolean("enabled",false)||v<=version(current)){handler.post{busy=false;if(manual)notify("当前版本 "+current.versionName+" · "+(if(j.optBoolean("enabled",false))"已是最新版本" else "更新渠道暂未开放"))};return@Thread}
    val expected=j.getString("sha256").lowercase();require(expected.matches(Regex("[0-9a-f]{64}")))
    val size=j.getLong("size");require(size in 1L..900_000_000L)
    val url=j.getString("url")
    val parsed=URL(url)
    val prefix=if(signer=="065d80ddf51e5a7cbc881900351ee355cdd8aa2447fee0a959d0391ecc02c7ba")"starling-new-v" else "starling-v"
    require(parsed.protocol=="https"&&parsed.host=="raw.githubusercontent.com"&&parsed.port==-1&&parsed.userInfo==null&&parsed.query==null&&parsed.ref==null&&parsed.path=="/xinminyu168-spec/starling-3d-studio/main/updates/"+prefix+v+".apk"){"更新下载地址不匹配"}
    val candidate=ApprovedUpdate(v,expected,size,url)
    if(approved==null){
     handler.post{
      busy=false
      if(!running||activity.isFinishing||activity.isDestroyed||dialog?.isShowing==true||(!manual&&prompted==v))return@post
      prompted=v
      val name=j.optString("versionName",v.toString())
      val note=j.optString("note","程序功能与渲染引擎更新").take(300)
      dialog=AlertDialog.Builder(activity).setTitle("发现新版本 "+name)
       .setMessage(note+"\n下载大小："+String.format(java.util.Locale.CHINA,"%.1f MB",size/1000000.0)+"\n点击立即更新后才开始下载。")
       .setNegativeButton("稍后",null).setPositiveButton("立即更新"){_,_->check(true,candidate)}.show()
     }
     return@Thread
    }
    require(candidate==approved){"云端安装包信息已改变，请重新检查"}
    StudioAssets.prepare(activity)
    val dir=File(activity.filesDir,"updates").apply{mkdirs()}
    val out=File(dir,"update-"+v+".apk")
    fun hash(f:File):String{val md=MessageDigest.getInstance("SHA-256");f.inputStream().use{val b=ByteArray(65536);while(true){val n=it.read(b);if(n<0)break;md.update(b,0,n)}};return hex(md.digest())}
    if(!out.exists()||out.length()!=size||hash(out)!=expected){
     require(dir.usableSpace>size+20_000_000L){"存储空间不足"}
     handler.post{notify("发现新版本，正在下载")}
     val temp=File(dir,"update-"+v+".part.apk")
     val c=connect(url)
     try{
      require(c.responseCode==200)
      val md=MessageDigest.getInstance("SHA-256");var total=0L
      c.inputStream.use{input->temp.outputStream().use{output->val b=ByteArray(65536);while(true){val n=input.read(b);if(n<0)break;total+=n;require(total<=size);output.write(b,0,n);md.update(b,0,n)}}}
      require(total==size&&hex(md.digest())==expected){"文件校验失败"}
      verify(temp,v)
      if(out.exists())out.delete()
      require(temp.renameTo(out))
     }finally{c.disconnect();temp.delete()}
    }
    verify(out,v)
    handler.post{busy=false;if(!activity.isFinishing&&!activity.isDestroyed&&running){prompted=v;showInstall(out,v)}}
   }catch(e:Exception){handler.post{busy=false;if(manual)notify("更新失败："+(e.message?:"网络异常"))}}
  }.start()
 }
 private fun showInstall(f:File,v:Long){
  if(dialog?.isShowing==true)return
  dialog=AlertDialog.Builder(activity).setTitle("新版本已下载").setMessage("已校验安装包及原应用签名。确认后覆盖安装，保留应用数据。").setNegativeButton("稍后",null).setPositiveButton("安装"){_,_->
   if(Build.VERSION.SDK_INT>=26&&!activity.packageManager.canRequestPackageInstalls()){
    prompted=0L
    activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,Uri.parse("package:"+activity.packageName)))
   }else{
    val uri=FileProvider.getUriForFile(activity,activity.packageName+".updates",f)
    try{activity.startActivity(Intent(Intent.ACTION_INSTALL_PACKAGE).setData(uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION).apply{clipData=android.content.ClipData.newRawUri("APK",uri)})}
    catch(e:Exception){prompted=0L;notify("无法启动系统安装器")}
   }
  }.show()
 }
}
EOF
cat > app/src/main/java/com/starling/filament/IrisPatch.kt <<'EOF'
package com.starling.filament
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.zip.InflaterInputStream
import android.util.Base64
// Derived, opt-in cache. Never mutate the canonical resource.
object IrisPatch {
 private const val SOURCE="97c80d3a7f5b8e6412687ab30574fa4efdb5cd4db0a3115356de426ae411e379"
 private const val OUTPUT="e77bea914c1c4f804a0d61f5b17167422e522f02085c772bf4100b8f5dd343e5"
 private const val HEADER="eNrdl91uIjcUx1GlfYFe9RLNVS9oah9/jM1dNt20qbJhFVBUqYoiAw5xO8wgM+xmhXiCfZ++Q9+nD9DjYUImM4EN3VQr5SbCxufn8z8f5mSSDI6/abVa3//96dU/37Zav/Z7Z8vIzOc2j7rL6L31c5elUTeCAxJ1oolNrTd55nGnnxufuHTSvmDtkUnHbmxy257iH+9M0p4Zn7s8GK860XyEhlGXlJ/mUff3ZZRm4+ITuVxddjarZTS185vibGqmaBT1vJu4FJGjG+PNCPlRMAjHSouZd1O86325NHnu3XCRh+UyetfrnwxOemcF8qx3/vbwNOrSTjR489tRr3f+0xWJuoA+OpQwCiYc2aUKtFl1vhgoqkD6DEBZBcIzAOMqkD0DUFWB/BmAugqUzwCkpEqMV0UR3m2UBbquv5+Lok+w/GdD/9bmJknc6DxbTG6wkovLh2Zuj7Ik8wN7my+8DXt4kb0t6gcrtWbTPEYrx46xxkOHoff+zmKztwqd4qcmaTIgdJdJQp8dCIEHx9limNi+G9tx1M39woawlaL6f7r0atO2L0vbL8b5l6rtdbKwV9dm6N3opUp8Z1ya2/EVPu9J8lJFFjpeqrgT7+b32q6+1gNKDsgjKsmBFE8UCvvp/Mpv6v8kF38W3dRMytlquLi+tv7C2Q/rQclN7eDjLASjOPTjHzM7iUKIqgfFIwdnafOc3ApEJ/K172s35tnCj8qJ0kxnifXlqHb3Bd32BTz44nKzKmdPMzl2SRgxuzqGMHS4dLOhFc5JH7yZ9cP4wHW5GpSrADMjHC7mmW8GCz0dZdNZlto0XwsUFGTYXKR5IICUHIn5WvzFmyMWFdcj6QdywIniGrQCpmLBIe6EbOM+UK6kFJpxRSglNC6mmNswVj9mo2P8qGMiCRAmBHQeI9TTQv+D63UG7M2ABoM9xhAbhlCKaiE3jP7R4enheYMS76YwACG1rlPuUkE38V27LBvRUrv5oISMxTY8VPGgFG/g9WfwRABj2/D8gfeC6GauyW6+5lpq2MZXn40Opbv5FKjggmy7gGwu0JpiHC/3zC7lfGtmNUB83z5AONEhXsOPue1dXxf/EVPQBGIt98y5ZNsvJbrSsxRVxaR+KcXeJcVbdX9n9YEpHpeqRbk8tekkvwleM6pjGZQbPwkHGGYR7kU0APcWX8YBLpkWoB5yFFBGY/l0DMOmwRDU3AGGmwpq7rAdHCGZIg138N0DQfkOO0mpYoTX7heaKqrULrsY31NgUPObo3y+S6/U6A8LEXoYfk0Yi+HpejE4NI55TW+oJ0zKHhgmJMEKrGeRaLYPhTNFZT0YLMZfVan2wGDMsTVJPYcSt0kds2mZsl0qFhoTChDaatVut7/769Or1ydnrX8BeUggBA=="
 private fun sha(f:File):String{
  val md=MessageDigest.getInstance("SHA-256")
  f.inputStream().use{input->val b=ByteArray(65536);while(true){val n=input.read(b);if(n<0)break;md.update(b,0,n)}}
  return md.digest().joinToString(""){"%02x".format(it)}
 }
 @Synchronized fun prepare(src:File,dir:File):File{
  require(src.length()==93046212L&&sha(src)==SOURCE){"原模型版本不匹配"}
  val dst=File(dir,"iris-test-v1.glb")
  if(dst.length()==93047080L&&sha(dst)==OUTPUT)return dst
  require(dir.usableSpace>110_000_000L){"缓存空间不足"}
  val tmp=File(dir,"iris-test-v1.part")
  try{
   val head=InflaterInputStream(Base64.decode(HEADER,Base64.DEFAULT).inputStream()).use{it.readBytes()}
   require(head.size==4880)
   RandomAccessFile(src,"r").use{input->
    tmp.outputStream().buffered(65536).use{out->
     out.write(head)
     val buf=ByteArray(65536)
     fun copy(from:Long,to:Long){
      require(from>=0&&to>=from&&to<=93042200L)
      input.seek(4012L+from)
      var n=to-from
      while(n>0){val c=minOf(n,buf.size.toLong()).toInt();input.readFully(buf,0,c);out.write(buf,0,c);n-=c}
     }
     var pos=0L
     fun split(off:Long,count:Int,ids:IntArray){
      require(ids.isNotEmpty()&&ids.all{it in 0 until count}&&ids.toList().zipWithNext().all{it.first<it.second})
      copy(pos,off)
      var start=0
      for(i in ids){copy(off+start*12L,off+i*12L);start=i+1}
      copy(off+start*12L,off+count*12L)
      for(i in ids)copy(off+i*12L,off+(i+1)*12L)
      pos=off+count*12L
     }
     split(69514376L,1075281,((520039..520065).toList()+listOf(520081,520084,520085,520086,520087,520088,520089,520090,520091,520092,520093,520094,520095,520097,520098,520099,520103,520150,520157,520159,520163)).toIntArray())
     split(82417748L,95246,intArrayOf(39528,39530,39531,39532,39533,39534,39543,39544,39545,39546,39547,39548,39549,39550,39611,39612,39613,39614,39615,39616,39684))
     copy(pos,93042200L)
    }
   }
   require(tmp.length()==93047080L&&sha(tmp)==OUTPUT){"虹膜缓存校验失败"}
   if(dst.exists())require(dst.delete())
   require(tmp.renameTo(dst)){"虹膜缓存写入失败"}
   return dst
  }finally{tmp.delete()}
 }
}
EOF
cat > app/src/main/java/com/starling/filament/StudioAssets.kt <<'EOF'
package com.starling.filament
import android.content.Context
import java.io.File
import java.security.MessageDigest
object StudioAssets {
 private val expected=mapOf(
 "viewer.html" to (174910L to "9bffc2df459eebf0bbd871416c811de379bb069938904d10ebf127fb89621376"),
 "studio_env.rgba" to (917504L to "685a171c95fb12ac87563bfd9aee2909ade1450654cedac6d2f710db80cf2efc"),
 "reference.png" to (111244L to "fd04e1f6d3bf8cb10e9865215b52cebc1ec8da852d80bf6b717f0e51bbd6b9fa"),
 "full.glb" to (69516136L to "e094d87c9de30b26d67c7089dac00cf159a4ca9966530f1ef938378c06e55ee6"),
 "mobile.glb" to (14004536L to "d55824a6514a6ab52f0e3d9d0cc0ed9ba3d346207d64e60595326db912fd66f4"),
 "original_source.zip" to (59564696L to "80e95e1adfbc05cda5c527e1d8bc3780feb85806893ae5a1c6cb05570664f27d"),
 "native_full.glb" to (93046212L to "97c80d3a7f5b8e6412687ab30574fa4efdb5cd4db0a3115356de426ae411e379")
 )
 private fun directory(c:Context)=File(c.filesDir,"studio-assets")
 @Synchronized fun prepare(c:Context){
  val dir=directory(c).apply{mkdirs()}
  for((name,spec) in expected){
   val dst=File(dir,name)
   if(dst.exists()&&dst.length()==spec.first)continue
   require(dir.usableSpace>spec.first+10_000_000L){"可用空间不足"}
   val tmp=File(dir,name+".part")
   try{
    val md=MessageDigest.getInstance("SHA-256")
    c.assets.open(name).use{input->tmp.outputStream().use{output->val b=ByteArray(65536);var total=0L;while(true){val n=input.read(b);if(n<0)break;total+=n;require(total<=spec.first);md.update(b,0,n);output.write(b,0,n)};require(total==spec.first)}}
    require(md.digest().joinToString(""){"%02x".format(it)}==spec.second){"内置素材校验失败："+name}
    if(dst.exists())dst.delete()
    require(tmp.renameTo(dst))
   }finally{tmp.delete()}
  }
 }
 // Restore only the immutable, hash-pinned assets, never arbitrary files or preferences.
 @Synchronized fun importBackup(c:Context,input:java.io.InputStream){
  val dir=directory(c)
  val staged=File(c.filesDir,"studio-assets-import")
  val old=File(c.filesDir,"studio-assets-previous")
  // Recover a previous interrupted rename; do not overwrite any preexisting backup.
  if(!dir.exists()&&old.exists())require(old.renameTo(dir)){"上次恢复未完成"}
  require(!old.exists()){"存在旧素材保护副本，请先保留并检查"}
  require(staged.deleteRecursively()&&staged.mkdirs()){"无法准备恢复目录"}
  require(staged.usableSpace>expected.values.sumOf{it.first}+10_000_000L){"可用空间不足"}
  try{
   val seen=mutableSetOf<String>()
   java.util.zip.ZipInputStream(java.io.BufferedInputStream(input)).use{zip->
    while(true){
     val entry=zip.nextEntry?:break
     val name=entry.name
     val spec=expected[name]?:error("不允许的备份条目："+name)
     require(!entry.isDirectory&&seen.add(name)){"重复或无效素材："+name}
     val md=MessageDigest.getInstance("SHA-256")
     File(staged,name).outputStream().use{out->
      val buf=ByteArray(65536);var total=0L
      while(true){val n=zip.read(buf);if(n<0)break;total+=n;require(total<=spec.first){"素材大小超限："+name};md.update(buf,0,n);out.write(buf,0,n)}
      require(total==spec.first){"素材长度不一致："+name}
     }
     require(md.digest().joinToString(""){"%02x".format(it)}==spec.second){"素材哈希不一致："+name}
     zip.closeEntry()
    }
   }
   require(seen==expected.keys){"缺少必需素材"}
   if(dir.exists())require(dir.renameTo(old)){"无法保护旧素材"}
   if(!staged.renameTo(dir)){
    if(old.exists())old.renameTo(dir)
    error("无法提交已校验素材")
   }
   if(old.exists())old.deleteRecursively()
  }finally{staged.deleteRecursively()}
 }
 fun file(c:Context,name:String):File{
  val spec=expected[name]?:error("未知资源")
  val f=File(directory(c),name)
  require(f.exists()&&f.length()==spec.first){"本地素材未准备："+name}
  return f
 }
}
EOF
cat > app/src/main/assets/studio-controls.js <<'EOF'
'use strict';
const $=id=>document.getElementById(id),cv=$('cv');
const defaults={exposure:1.04,key:1,ambient:1,rough:1.0,normal:.3,skin:.55,reflect:.85};
const names=Object.keys(defaults);
function send(c,d={}){Studio.send(c,JSON.stringify(d))}
let yaw=0,pitch=0,zoom=1,x=0,y=0,spin=false,compare=false;
function pose(){send('pose',{yaw,pitch,zoom,x,y,spin})}
function clamp(n,a,b){return Math.max(a,Math.min(b,n))}
function view(a){yaw=a;pitch=0;zoom=1;x=y=0;spin=false;$('spin').textContent='自动旋转';pose()}
let pointers=new Map(),queued=false;
function queue(){if(!queued){queued=true;requestAnimationFrame(()=>{queued=false;pose()})}}
cv.addEventListener('pointerdown',e=>{cv.setPointerCapture(e.pointerId);pointers.set(e.pointerId,[e.clientX,e.clientY]);spin=false;$('spin').textContent='自动旋转';queue()});
cv.addEventListener('pointermove',e=>{let old=pointers.get(e.pointerId);if(!old)return;let now=[e.clientX,e.clientY],other=[...pointers.entries()].find(([id])=>id!==e.pointerId);if(other){let a=other[1],d0=Math.hypot(old[0]-a[0],old[1]-a[1]),d1=Math.hypot(now[0]-a[0],now[1]-a[1]);if(d0>3&&d1>3)zoom=clamp(zoom*d1/d0,.3,2.5);x=clamp(x+(now[0]-old[0])*.003,-1.5,1.5);y=clamp(y-(now[1]-old[1])*.003,-1.5,1.5)}else{yaw=(yaw+(now[0]-old[0])*.5)%360;pitch=clamp(pitch+(now[1]-old[1])*.5,-85,85)}pointers.set(e.pointerId,now);queue()});
for(const e of ['pointerup','pointercancel','lostpointercapture'])cv.addEventListener(e,a=>pointers.delete(a.pointerId));
$('front').onclick=()=>view(0);$('side').onclick=()=>view(90);$('back').onclick=()=>view(180);$('reset').onclick=()=>view(0);
$('spin').onclick=()=>{spin=!spin;$('spin').textContent=spin?'停止旋转':'自动旋转';pose()};
$('settings').onclick=()=>{$('panel').style.display=$('panel').style.display==='block'?'none':'block'};
$('compare').onclick=()=>{compare=!compare;document.body.classList.toggle('compare',compare);$('ref').style.display=compare?'block':'none';send('compare',{show:compare})};
function params(){let p={};for(const n of names){p[n]=Number($(n).value);$(n+'V').value=p[n].toFixed(2)}p.flat=$('light').value==='0';return p}
function apply(p){for(const n of names)if(Number.isFinite(p[n]))$(n).value=p[n];if(typeof p.flat==='boolean')$('light').value=p.flat?'0':'1';send('params',params())}
for(const n of names)$(n).oninput=()=>send('params',params());
for(const n of ['rough','normal']){$(n).disabled=true;$(n).title='保真模式：保留模型原始材质'};$('skin').disabled=true;$('skin').title='独立皮肤候选区微表面柔化，非 SSS';$('skin').parentElement.firstChild.textContent='皮肤细节柔化 ';$('reflect').disabled=true;$('reflect').title='恢复模式：环境反射与漫反射保持官方 IBL 默认比例';
$('light').options[1].textContent='柔和平光';$('light').onchange=()=>send('params',params());
$('quality').onchange=()=>send('quality',{value:Number($('quality').value)});
$('save').onclick=()=>send('save',params());window.studioDefaults=()=>apply({...defaults,flat:false});$('defaults').onclick=studioDefaults;
window.studioCloud=s=>{try{apply(JSON.parse(s));send('save',params())}catch(e){}};
window.studioRestore=s=>{try{let p=JSON.parse(s||"{}");apply(p)}catch(e){studioDefaults()}};
window.studioStatus=s=>{$('status').textContent=s};
window.studioModel=m=>{$('model').value=m;$('switchModel').textContent=m==='full'?'切换轻量版':'切换高精度'};
window.studioLoaded=m=>{$('skin').disabled=true;sssButton.disabled=true;hairButton.disabled=true;shellButton.disabled=true;studioShell(false);clothButton.disabled=true;studioCloth(false);studioSSS(false);studioHair(false);studioModel(m);$('msg').style.display='none';$('modelinfo').textContent=m==='full'?'离线高精度模型 · 4K':'离线轻量模型 · 2K'};
function change(m){studioModel(m);$('msg').style.display='block';$('msg').textContent='正在加载模型…';send('model',{mode:m})}
$('model').onchange=()=>change($('model').value);$('switchModel').onclick=()=>change($('model').value==='full'?'mobile':'full');
$('endpoint').value='https://xinminyu168-spec.github.io/starling-3d-studio/';$('endpoint').readOnly=true;$('check').onclick=()=>send('check');$('rollback').onclick=()=>send('rollback');
window.studioProgress=p=>{$('msg').style.display='block';$('msg').textContent='正在加载纹理 '+p+'%';$('modelinfo').textContent='纹理加载 '+p+'%'};
window.studioFailure=s=>{$('msg').style.display='block';$('msg').textContent=s;$('modelinfo').textContent='加载失败'};
window.studioDiagnostic=on=>{uvAutoButton.disabled=!on;uvButton.disabled=!on;if(on)$('modelinfo').textContent='仅色彩图诊断 · 原始 UV';studioUvProbe(false)};
window.studioRegions=on=>{$('skin').disabled=!on;sssButton.disabled=!on;hairButton.disabled=!on;shellButton.disabled=!on;clothButton.disabled=!on;if(on)$('modelinfo').textContent='高精度 · 4K · 独立材质分区'};
window.studioSkin=v=>{$('skin').value=v;$('skinV').value=Number(v).toFixed(2)};
const look=document.createElement("button");look.textContent="影视级 / 保真";look.style.margin="4px";let cine=true;window.studioLook=on=>{cine=on;look.textContent=on?"影视级：开启（点击保真）":"保真：开启（点击影视级）"};look.onclick=()=>send("cinematic",{enabled:!cine});$("check").insertAdjacentElement("afterend",look);
const polish=document.createElement("button");polish.style.margin="4px";let refine=true;window.studioRefine=on=>{refine=on;polish.textContent=on?"材质精修：开启":"材质精修：关闭"};studioRefine(true);polish.onclick=()=>send("refineAtlas",{enabled:!refine});$("check").insertAdjacentElement("afterend",polish);
const face=document.createElement('button');face.textContent='面部近景';face.style.margin='4px';face.onclick=()=>{yaw=0;pitch=0;zoom=2.5;x=0;y=-1.24;spin=false;$('spin').textContent='自动旋转';pose();$('panel').style.display='none'};$('check').insertAdjacentElement('afterend',face);
const sssButton=document.createElement('button');sssButton.style.margin='4px';sssButton.disabled=true;let sss=false;window.studioSSS=on=>{sss=on;const pores=$('studioPoresRange');if(pores)pores.disabled=!on;sssButton.textContent=on?'皮肤散射：开启':'皮肤散射：关闭（UV 修复测试）'};studioSSS(false);sssButton.onclick=()=>send('sss',{enabled:!sss});$('check').insertAdjacentElement('afterend',sssButton);
const hairButton=document.createElement('button');hairButton.style.margin='4px';hairButton.disabled=true;let hairOn=false;window.studioHair=on=>{hairOn=on;hairButton.textContent=on?'发束反射：开启':'发束反射：关闭（UV 修复测试）'};studioHair(false);hairButton.onclick=()=>send('hair',{enabled:!hairOn});$('check').insertAdjacentElement('afterend',hairButton);
const clothButton=document.createElement('button');clothButton.style.margin='4px';clothButton.disabled=true;let clothOn=false;window.studioCloth=on=>{clothOn=on;clothButton.textContent=on?'织物微表面：开启':'织物微表面：关闭（UV 修复测试）'};studioCloth(false);clothButton.onclick=()=>send('cloth',{enabled:!clothOn});$('check').insertAdjacentElement('afterend',clothButton);
const shellButton=document.createElement('button');shellButton.style.margin='4px';shellButton.disabled=true;let shellOn=false;window.studioShell=on=>{shellOn=on;shellButton.textContent=on?'外壳双层烤漆：开启':'外壳双层烤漆：关闭（UV 修复测试）'};studioShell(false);shellButton.onclick=()=>send('shell',{enabled:!shellOn});$('check').insertAdjacentElement('afterend',shellButton);
const poreWrap=document.createElement('label');poreWrap.style.display='block';poreWrap.style.margin='8px 4px';poreWrap.textContent='皮肤微细节 ';
const poreValue=document.createElement('span');poreValue.textContent='0.35';poreWrap.appendChild(poreValue);
const poreRange=document.createElement('input');poreRange.type='range';poreRange.id='studioPoresRange';poreRange.min='0';poreRange.max='1';poreRange.step='.01';poreRange.value='.35';poreRange.disabled=true;poreRange.style.width='100%';poreWrap.appendChild(poreRange);sssButton.insertAdjacentElement('afterend',poreWrap);
window.studioPores=v=>{poreRange.value=v;poreValue.textContent=Number(v).toFixed(2)};poreRange.oninput=()=>{const v=Number(poreRange.value);studioPores(v);send('pores',{value:v})};
const maxButton=document.createElement('button');maxButton.textContent='最高画质 · 安全 PBR';maxButton.style.margin='4px';maxButton.onclick=()=>send('maximum');$('check').insertAdjacentElement('afterend',maxButton);
window.studioMaximum=()=>{if(window.studioLightProfile)studioLightProfile(0);studioLook(true);studioRefine(true);studioModel('full');$('quality').value='2';studioDefaults();send('quality',{value:2})};
const irisButton=document.createElement('button');irisButton.textContent='虹膜反射 · 试验关闭';irisButton.style.margin='4px';irisButton.onclick=()=>send('irisTest');$('check').insertAdjacentElement('afterend',irisButton);
window.studioIris=on=>{irisButton.textContent='虹膜反射 · '+(on?'试验开启':'试验关闭')};
const portraitButton=document.createElement('button');portraitButton.textContent='肖像精修 · 单项对照';portraitButton.style.margin='4px';portraitButton.onclick=()=>send('portrait');$('check').insertAdjacentElement('afterend',portraitButton);
const lightingButton=document.createElement('button');lightingButton.textContent='灯光校准 · 标准三点布光';lightingButton.style.margin='4px';lightingButton.onclick=()=>send('lightProfile');$('check').insertAdjacentElement('afterend',lightingButton);
window.studioLightProfile=i=>{lightingButton.textContent='灯光校准 · '+['标准三点布光','柔和棚拍','轮廓造型','角色肖像'][i]};
const safeButton=document.createElement('button');safeButton.textContent='恢复原始 PBR 材质';safeButton.style.margin='4px';safeButton.onclick=()=>send('safeMaterials');$('check').insertAdjacentElement('afterend',safeButton);
const compareMaterials=document.createElement('button');compareMaterials.textContent='高级材质 / PBR 对照';compareMaterials.style.margin='4px';compareMaterials.onclick=()=>send('materialCompare');$('check').insertAdjacentElement('afterend',compareMaterials);
const auditButton=document.createElement('button');auditButton.textContent='渲染诊断报告';auditButton.style.margin='4px';auditButton.onclick=()=>send('renderAudit');$('check').insertAdjacentElement('afterend',auditButton);
const exportLock=document.createElement('div');exportLock.style.cssText='display:none;position:fixed;inset:0;background:rgba(0,0,0,.48);color:white;z-index:2147483647;align-items:center;justify-content:center;text-align:center;padding:24px;touch-action:none';exportLock.textContent='正在原生离屏渲染并写入相册，请保持 APP 在前台';document.body.appendChild(exportLock);
window.studioExportLock=on=>{exportLock.style.display=on?'flex':'none';pointers.clear()};
const exportButton=document.createElement('button');exportButton.textContent='超高清渲染输出';exportButton.style.margin='4px';exportButton.onclick=()=>send('export');$('check').insertAdjacentElement('afterend',exportButton);
const uvButton=document.createElement('button');uvButton.style.margin='4px';uvButton.disabled=true;window.studioUvProbe=on=>{uvButton.textContent=on?'UV 对照 B · 点击回到 A':'UV 对照 A · 点击切换 B'};studioUvProbe(false);uvButton.onclick=()=>send('uvProbe');$('check').insertAdjacentElement('afterend',uvButton);
const uvAutoButton=document.createElement('button');uvAutoButton.textContent='自动 UV 一致性检测';uvAutoButton.style.margin='4px';uvAutoButton.disabled=true;uvAutoButton.onclick=()=>send('uvAuto');$('check').insertAdjacentElement('afterend',uvAutoButton);
const diag=document.createElement('button');diag.textContent='纹理诊断';diag.style.margin='4px';diag.onclick=()=>send('diagnose');$('check').insertAdjacentElement('afterend',diag);
window.studioReady=()=>{studioDefaults();send('ready');send('restore');send('quality',{value:2})};studioReady();
EOF

# Build the same prefiltered environment format used by Filament's Android samples.
# Pinned engine version, public CC0 environment only; no private character data.
if [ "${STARLING_SKIP_IBL:-0}" != 1 ]; then
 tmp="$(mktemp -d)"
 curl --fail --location --retry 3 --max-time 180 'https://github.com/google/filament/releases/download/v1.56.0/filament-v1.56.0-linux.tgz' -o "$tmp/filament.tgz"
 tar -xzf "$tmp/filament.tgz" -C "$tmp"
 cmgen="$(find "$tmp" -type f -name cmgen -print -quit)"
 test -x "$cmgen"
 curl --fail --location --retry 3 --max-time 90 'https://raw.githubusercontent.com/google/filament/v1.56.0/third_party/environments/lightroom_14b.hdr' -o "$tmp/studio.hdr"
 mkdir -p "$tmp/ibl"
 "$cmgen" -q --format=ktx --size=256 --extract-blur=0.1 --deploy="$tmp/ibl" "$tmp/studio.hdr"
 ibl="$(find "$tmp/ibl" -name '*_ibl.ktx' -print -quit)"
 test -s "$ibl"
 cp "$ibl" app/src/main/assets/studio_ibl.ktx
 mkdir -p app/src/main/res/raw
 cat > "$tmp/studio_skin.mat" <<'MAT'
material {
    name : Studio_skin_SSS,
    flipUV : false,
    shadingModel : subsurface,
    requires : [ uv0 ],
    parameters : [
        { type : sampler2d, name : baseColorMap },
        { type : sampler2d, name : normalMap },
        { type : sampler2d, name : metallicRoughnessMap },
        { type : float, name : softness },
        { type : float, name : poreStrength }
    ],
    doubleSided : true
}
fragment {
    void material(inout MaterialInputs material) {
        highp vec2 uv = getUV0();
        float t = clamp(materialParams.softness, 0.0, 1.0);
        vec3 n = texture(materialParams_normalMap, uv).xyz * 2.0 - 1.0;
        vec4 albedo = texture(materialParams_baseColorMap, uv);
        vec3 mr = texture(materialParams_metallicRoughnessMap, uv).rgb;
        float detail = clamp(materialParams.poreStrength, 0.0, 1.0);
        // UV-space synthetic pores: not anatomical texture data.
        // The compact support stays inside each jittered cell, so no cell-edge seams.
        vec2 grid = uv * 1450.0;
        vec2 cell = floor(grid);
        vec2 center = vec2(0.5) + 0.28 * (fract(sin(vec2(dot(cell, vec2(127.1,311.7)), dot(cell,vec2(269.5,183.3)))) * 43758.5453) - 0.5);
        vec2 d = fract(grid) - center;
        float radius = 0.17 + 0.07 * fract(sin(dot(cell,vec2(73.13,195.27))) * 43758.5453);
        float radial = length(d) / radius;
        float envelope = 1.0 - smoothstep(0.05,1.0,radial);
        vec2 slope = (d / max(length(d), 0.001)) * (4.0 * radial * envelope);
        vec2 footprint = fwidth(grid);
        float fade = 1.0 - smoothstep(0.12, 0.42, max(footprint.x,footprint.y));
        float skinMask = (1.0 - smoothstep(0.02,0.15,mr.b)) * smoothstep(0.015,0.08,albedo.r-albedo.b);
        float pore = detail * fade * skinMask;
        material.normal = normalize(vec3(n.xy * mix(0.55, 0.28, t) + slope * (0.04 * pore), max(n.z, 0.01)));
        prepareMaterial(material);
        material.baseColor = albedo;
        material.metallic = mr.b;
        // Soften highlights only on warm non-metal skin candidates; preserve authored atlas.
        float roughBase = clamp(mr.g * mix(0.92, 1.0, t), 0.08, 1.0);
        material.roughness = clamp(mix(roughBase, max(roughBase, 0.60), skinMask * t) + 0.035 * envelope * pore, 0.08, 1.0);
        material.reflectance = mix(0.45, 0.27, skinMask * t) - 0.015 * envelope * pore;
        // A colour-derived scattering proxy, not measured physical skin thickness.
        float warm = smoothstep(0.015, 0.14, albedo.r-albedo.b) * skinMask;
        material.thickness = clamp(mix(0.90, 0.58, t) - 0.10 * warm * t, 0.45, 0.95);
        material.subsurfaceColor = albedo.rgb * vec3(0.34, 0.19, 0.13) * t * skinMask;
        material.subsurfacePower = 5.0;
    }
}
MAT
 matc="$(find "$tmp" -type f -name matc -print -quit)"
 test -x "$matc"
 "$matc" -p mobile -a opengl -o app/src/main/res/raw/studio_skin.filamat "$tmp/studio_skin.mat"
 test -s app/src/main/res/raw/studio_skin.filamat
 cat > "$tmp/studio_hair.mat" <<'MAT'
material {
    name : Studio_hair_anisotropic,
    flipUV : false,
    shadingModel : lit,
    requires : [ uv0 ],
    parameters : [
        { type : sampler2d, name : baseColorMap },
        { type : sampler2d, name : normalMap },
        { type : sampler2d, name : metallicRoughnessMap },
        { type : float, name : strength }
    ],
    doubleSided : true
}
fragment {
    void material(inout MaterialInputs material) {
        highp vec2 uv = getUV0();
        vec3 n = texture(materialParams_normalMap, uv).xyz * 2.0 - 1.0;
        material.normal = normalize(vec3(n.xy * 0.48, max(n.z, 0.01)));
        prepareMaterial(material);
        vec3 mr = texture(materialParams_metallicRoughnessMap, uv).rgb;
        material.baseColor = texture(materialParams_baseColorMap, uv);
        material.metallic = mr.b;
        float strandMask = 1.0 - smoothstep(0.04, 0.25, mr.b);
        material.roughness = clamp(mix(mr.g, max(mr.g, 0.40), strandMask * 0.70), 0.08, 1.0);
        material.reflectance = mix(0.5, 0.36, strandMask);
        material.anisotropy = clamp(materialParams.strength, 0.0, 0.65) * strandMask;
        material.anisotropyDirection = vec3(0.0, 1.0, 0.0);
    }
}
MAT
 "$matc" -p mobile -a opengl -o app/src/main/res/raw/studio_hair.filamat "$tmp/studio_hair.mat"
 test -s app/src/main/res/raw/studio_hair.filamat
 cat > "$tmp/studio_cloth.mat" <<'MAT'
material {
    name : Studio_cloth_sheen,
    flipUV : false,
    shadingModel : lit,
    requires : [ uv0 ],
    parameters : [
        { type : sampler2d, name : baseColorMap },
        { type : sampler2d, name : normalMap },
        { type : sampler2d, name : metallicRoughnessMap },
        { type : float, name : strength }
    ],
    doubleSided : true
}
fragment {
    void material(inout MaterialInputs material) {
        highp vec2 uv = getUV0();
        vec3 n = texture(materialParams_normalMap, uv).xyz * 2.0 - 1.0;
        vec3 mr = texture(materialParams_metallicRoughnessMap, uv).rgb;
        vec4 albedo = texture(materialParams_baseColorMap, uv);
        float t = clamp(materialParams.strength, 0.0, 1.0);
        float dielectric = 1.0 - smoothstep(0.02, 0.12, mr.b);
        float blue = smoothstep(0.025,0.14,albedo.b-albedo.r);
        float mask = dielectric * max(smoothstep(0.45,0.62,mr.g), blue * smoothstep(0.25,0.48,mr.g));
        vec2 grid = uv * 850.0;
        vec2 footprint = fwidth(grid);
        float fade = 1.0 - smoothstep(0.18, 0.48, max(footprint.x, footprint.y));
        vec2 weave = vec2(sin(grid.x * 6.2831853) * cos(grid.y * 3.1415927),
                          cos(grid.x * 3.1415927) * sin(grid.y * 6.2831853));
        material.normal = normalize(vec3(n.xy * 0.62 + weave * (0.026 * mask * fade * t), max(n.z, 0.01)));
        prepareMaterial(material);
        material.baseColor = albedo;
        material.metallic = mr.b;
        material.roughness = clamp(mix(mr.g, max(mr.g,0.75), mask*t), 0.08, 1.0);
        material.reflectance = mix(0.5,0.30,mask*t);
        material.sheenColor = sqrt(max(albedo.rgb, vec3(0.0))) * (0.08 * mask * t);
        material.sheenRoughness = 0.85;
    }
}
MAT
 "$matc" -p mobile -a opengl -o app/src/main/res/raw/studio_cloth.filamat "$tmp/studio_cloth.mat"
 test -s app/src/main/res/raw/studio_cloth.filamat
 cat > "$tmp/studio_shell.mat" <<'MAT'
material {
    name : Studio_shell_clearcoat,
    flipUV : false,
    shadingModel : lit,
    requires : [ uv0 ],
    parameters : [
        { type : sampler2d, name : baseColorMap },
        { type : sampler2d, name : normalMap },
        { type : sampler2d, name : metallicRoughnessMap },
        { type : float, name : strength }
    ],
    doubleSided : true
}
fragment {
    void material(inout MaterialInputs material) {
        highp vec2 uv = getUV0();
        vec3 n = texture(materialParams_normalMap, uv).xyz * 2.0 - 1.0;
        vec3 mr = texture(materialParams_metallicRoughnessMap, uv).rgb;
        vec4 albedo = texture(materialParams_baseColorMap, uv);
        float t = clamp(materialParams.strength, 0.0, 1.0);
        float mask = (1.0 - smoothstep(0.04, 0.18, mr.b)) * (1.0 - smoothstep(0.48, 0.72, mr.g));
        material.normal = normalize(vec3(n.xy * 0.48, max(n.z, 0.01)));
        prepareMaterial(material);
        material.baseColor = albedo;
        material.metallic = mr.b;
        material.roughness = clamp(mix(mr.g, max(mr.g,0.40),mask*t), 0.08, 1.0);
        material.reflectance = 0.5;
        material.clearCoat = 0.24 * mask * t;
        material.clearCoatRoughness = 0.44;
    }
}
MAT
 "$matc" -p mobile -a opengl -o app/src/main/res/raw/studio_shell.filamat "$tmp/studio_shell.mat"
 test -s app/src/main/res/raw/studio_shell.filamat
 cat > "$tmp/studio_uv_probe.mat" <<'MAT'
material {
    name : Studio_UV_Probe,
    flipUV : false,
    shadingModel : unlit,
    requires : [ uv0 ],
    parameters : [
        { type : sampler2d, name : baseColorMap }
    ],
    doubleSided : true
}
fragment {
    void material(inout MaterialInputs material) {
        highp vec2 uv = getUV0();
        prepareMaterial(material);
        material.baseColor = texture(materialParams_baseColorMap, uv);
    }
}
MAT
 # Regression guard: every atlas sampling shader must use glTF orientation.
 for shader in studio_skin studio_hair studio_cloth studio_shell studio_uv_probe; do
  grep -Eq '^ *flipUV *: *false,' "$tmp/$shader.mat"
  grep -Eq 'highp vec2 uv = getUV0\(\);' "$tmp/$shader.mat"
 done
 "$matc" -p mobile -a opengl -o app/src/main/res/raw/studio_uv_probe.filamat "$tmp/studio_uv_probe.mat"
 test -s app/src/main/res/raw/studio_uv_probe.filamat
 rm -rf "$tmp"
fi
