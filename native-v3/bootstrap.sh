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
  versionCode 38
  versionName '3.6'
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
   if(spinning){yaw=(yaw+0.45f)%360f;applyTransform()}
   viewer.render(t)
   if (t-lastCheck>30_000_000_000L) { lastCheck=t; if(initialized&&!pausedResources)sync() }
   frames.postFrameCallback(this)
  }
 }
 private lateinit var web:android.webkit.WebView
 private var initialized=false
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
  viewer.scene.skybox=Skybox.Builder().color(0.017f,0.02f,0.027f,1f).build(engine)
  viewer.view.ambientOcclusion=com.google.android.filament.View.AmbientOcclusion.NONE
  viewer.view.antiAliasing=com.google.android.filament.View.AntiAliasing.FXAA
  viewer.view.renderQuality=viewer.view.renderQuality.apply { hdrColorBuffer=com.google.android.filament.View.QualityLevel.HIGH }
  viewer.view.dynamicResolutionOptions=viewer.view.dynamicResolutionOptions.apply { enabled=false }
  viewer.view.multiSampleAntiAliasingOptions=viewer.view.multiSampleAntiAliasingOptions.apply { enabled=true; sampleCount=4 }
  addLight(-0.6f,-0.45f,-0.8f,32000f)
  addLight(0.6f,-0.25f,-0.8f,24000f)
  addLight(0.4f,-0.5f,0.7f,14000f)
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
      val ui=original.substringBefore("<script").replace("V2.3","V3.6").replace("前台每30秒检查资源；回退后暂停，手动同步可恢复。不更新 APP 程序。","自动检测版本，确认后才下载更新。").replace("检查并同步","检查更新")
      val script=assets.open("studio-controls.js").bufferedReader().use{it.readText()}
      val html=ui+"<style>html,body,canvas{background:transparent!important}body.compare canvas{margin-left:43%;width:57%}</style><script>"+script+"</script></body></html>"
      android.webkit.WebResourceResponse("text/html","UTF-8",java.io.ByteArrayInputStream(html.toByteArray(Charsets.UTF_8)))
     }
    }catch(e:Exception){android.webkit.WebResourceResponse("text/plain","UTF-8",500,"Error",emptyMap(),java.io.ByteArrayInputStream("资源读取失败".toByteArray()))}
   }
   override fun onPageFinished(view:android.webkit.WebView,url:String){if(initialized)js("window.studioReady&&studioReady()")}
  }
  Thread{
   try{StudioAssets.prepare(this);runOnUiThread{
    if(!isDestroyed){
     initialized=true
     pausedResources=prefs.getBoolean("paused",false)
     if(!prefs.getBoolean("baseline36",false)){prefs.edit().remove("params").putBoolean("baseline36",true).putBoolean("paused",true).putString("model","full").apply();pausedResources=true}
     selected=prefs.getString("model","full")?:"full"
     if(selected!="mobile")selected="full"
     web.loadUrl("https://appassets.androidplatform.net/studio/viewer.html")
     lighting(1.04f,1f,1f)
     loadMode(selected)
     if(active){appUpdates.start();if(!pausedResources)sync()}
    }
   }}catch(e:Exception){runOnUiThread{if(!isDestroyed)android.app.AlertDialog.Builder(this).setMessage("本地素材准备失败："+e.message).setPositiveButton("确定",null).show()}}
  }.start()
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
  lighting(exp,if(flat)0f else keyPower,if(flat)2f else ambientPower)
 }
 inner class Controls {
  @android.webkit.JavascriptInterface fun send(command:String,data:String){
   if(data.length>4096)return
   runOnUiThread{
    if(!initialized||isDestroyed)return@runOnUiThread
    try{
     val j=JSONObject(data)
     when(command){
      "ready"->{js("studioStatus("+JSONObject.quote(status.text.toString())+");studioModel("+JSONObject.quote(selected)+")");if(viewer.asset!=null)js("studioLoaded("+JSONObject.quote(selected)+")")}
      "pose"->{yaw=j.optDouble("yaw",0.0).toFloat();pitch=j.optDouble("pitch",0.0).toFloat().coerceIn(-85f,85f);zoom=j.optDouble("zoom",1.0).toFloat().coerceIn(.3f,2.5f);panX=j.optDouble("x",0.0).toFloat().coerceIn(-1.5f,1.5f);panY=j.optDouble("y",0.0).toFloat().coerceIn(-1.5f,1.5f);spinning=j.optBoolean("spin",false);applyTransform()}
      "model"->{val m=j.optString("mode");if(m in listOf("full","mobile")&&m!=selected){selected=m;prefs.edit().putString("model",m).apply();loadMode(m)}}
      "quality"->{val q=j.optDouble("value",2.0);viewer.view.multiSampleAntiAliasingOptions=viewer.view.multiSampleAntiAliasingOptions.apply{enabled=q>1;sampleCount=if(q>=2)4 else 2};viewer.view.ambientOcclusion=com.google.android.filament.View.AmbientOcclusion.NONE}
      "params"->applyUiParams(j)
      "save"->{prefs.edit().putString("params",data).apply();status.text="渲染参数已保存"}
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
  val f=File(filesDir,"model-"+mode+".glb")
  // Recovery uses only the verified bundled source; no cached overrides.
  
  loadAsset(if(mode=="full")"full.glb" else "mobile.glb")
 }
 private fun loadAsset(name:String) {
  try {
   val dst=StudioAssets.file(this,name)
   load(dst)
  } catch(e:Exception) { status.text="内置模型加载失败："+e.message }
 }
 private fun addLight(x:Float,y:Float,z:Float,power:Float) {
  val id=EntityManager.get().create()
  LightManager.Builder(LightManager.Type.DIRECTIONAL).color(1f,1f,1f).intensity(power).direction(x,y,z).castShadows(false).build(viewer.engine,id)
  viewer.scene.addEntity(id)
 }
 private fun lighting(e:Float,k:Float,a:Float) {
  viewer.camera.setExposure(16f,1f/100f,100f*e)
  val lm=viewer.engine.lightManager
  lm.setIntensity(lm.getInstance(viewer.light),48000f*k)
  setEnvironment(a,if(flat)0f else reflectPower)
 }
 private fun load(f:File):Boolean {
  try {
   val n=f.length(); require(n in 20L..150_000_000L)
   val b=ByteBuffer.allocateDirect(n.toInt()).order(ByteOrder.LITTLE_ENDIAN)
   f.inputStream().channel.use { ch -> while(b.hasRemaining()) { if(ch.read(b)<0) error("文件不完整") } }
   b.flip(); require(b.getInt(0)==0x46546c67); require(b.getInt(4)==2); require(b.getInt(8)==n.toInt())
   viewer.loadModelGlb(b); require(viewer.asset!=null){"Filament 无法解析模型"}; viewer.transformToUnitCube(); val tm=viewer.engine.transformManager; baseTransform=tm.getTransform(tm.getInstance(viewer.asset!!.root),FloatArray(16)); applyTransform();status.text="模型已载入";js("studioLoaded("+JSONObject.quote(selected)+")");return true
  } catch(e:Exception) { status.text="加载失败："+e.message; return false }
 }
 override fun onActivityResult(requestCode:Int,resultCode:Int,data:Intent?) {
  super.onActivityResult(requestCode,resultCode,data)
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
  val c=connect(base+"app-update.json?t="+System.currentTimeMillis())
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
 fun check(manual:Boolean,approved:Long?=null){
  if(busy){if(manual)notify("正在检查或下载更新");return}
  busy=true
  if(manual)notify("正在检查程序版本…")
  Thread{
   try{
    val j=manifest()
    val v=j.optLong("versionCode",0)
    if(!j.optBoolean("enabled",false)||v<=version(installed())){handler.post{busy=false;if(manual)notify("暂无可安装的新程序版本")};return@Thread}
    if(approved==null){
     handler.post{
      busy=false
      if(!running||activity.isFinishing||activity.isDestroyed||dialog?.isShowing==true||(!manual&&prompted==v))return@post
      prompted=v
      val name=j.optString("versionName",v.toString())
      val size=j.optLong("size",0)
      val note=j.optString("note","程序功能与渲染引擎更新").take(300)
      dialog=AlertDialog.Builder(activity).setTitle("发现新版本 "+name)
       .setMessage(note+"\n下载大小："+String.format(java.util.Locale.CHINA,"%.1f MB",size/1000000.0)+"\n点击立即更新后才开始下载。")
       .setNegativeButton("稍后",null).setPositiveButton("立即更新"){_,_->check(true,v)}.show()
     }
     return@Thread
    }
    require(v==approved){"云端版本已改变，请重新检查"}
    StudioAssets.prepare(activity)
    val expected=j.getString("sha256").lowercase();require(expected.matches(Regex("[0-9a-f]{64}")))
    val size=j.getLong("size");require(size in 1L..900_000_000L)
    val url=j.getString("url")
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
for(const n of ['rough','normal']){$(n).disabled=true;$(n).title='保真模式：保留模型原始材质'};$('skin').disabled=true;$('skin').title='独立皮肤着色尚未迁移';$('reflect').disabled=true;$('reflect').title='恢复模式：环境反射与漫反射保持官方 IBL 默认比例';
$('light').options[1].textContent='柔和平光';$('light').onchange=()=>send('params',params());
$('quality').onchange=()=>send('quality',{value:Number($('quality').value)});
$('save').onclick=()=>send('save',params());window.studioDefaults=()=>apply({...defaults,flat:false});$('defaults').onclick=studioDefaults;
window.studioCloud=s=>{try{apply(JSON.parse(s));send('save',params())}catch(e){}};
window.studioRestore=s=>{try{let p=JSON.parse(s||localStorage.getItem('renderParams')||'{}');apply(p)}catch(e){studioDefaults()}};
window.studioStatus=s=>{$('status').textContent=s};
window.studioModel=m=>{$('model').value=m;$('switchModel').textContent=m==='full'?'切换轻量版':'切换高精度'};
window.studioLoaded=m=>{studioModel(m);$('msg').style.display='none';$('modelinfo').textContent=m==='full'?'离线高精度模型 · 4K':'离线轻量模型 · 2K'};
function change(m){studioModel(m);$('msg').style.display='block';$('msg').textContent='正在加载模型…';send('model',{mode:m})}
$('model').onchange=()=>change($('model').value);$('switchModel').onclick=()=>change($('model').value==='full'?'mobile':'full');
$('endpoint').value='https://xinminyu168-spec.github.io/starling-3d-studio/';$('endpoint').readOnly=true;$('check').onclick=()=>send('check');$('rollback').onclick=()=>send('rollback');
window.studioReady=()=>{send('ready');studioDefaults();send('quality',{value:2})};studioReady();$('msg').style.display='none';
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
 rm -rf "$tmp"
fi
