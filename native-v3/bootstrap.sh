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
  versionCode 32
  versionName '3.1'
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
  <activity android:name="com.starling.filament.MainActivity" android:exported="false" android:configChanges="orientation|screenSize|keyboardHidden" android:screenOrientation="sensorLandscape"/>
  <activity android:name="com.starling.filament.StudioActivity" android:exported="true" android:configChanges="orientation|screenSize|keyboardHidden">
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
 private var checking = false
 private var version = ""
 private var lastCheck = 0L
 private val frames = Choreographer.getInstance()
 private val ticker = object : Choreographer.FrameCallback {
  override fun doFrame(t: Long) {
   if (!active) return
   viewer.render(t)
   if (t-lastCheck>30_000_000_000L) { lastCheck=t; sync() }
   frames.postFrameCallback(this)
  }
 }
 override fun onCreate(savedInstanceState: Bundle?) {
  super.onCreate(savedInstanceState)
  window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
  val root = LinearLayout(this).apply { orientation=LinearLayout.VERTICAL; setBackgroundColor(Color.rgb(17,19,24)) }
  val top = LinearLayout(this).apply { orientation=LinearLayout.HORIZONTAL; gravity=Gravity.CENTER_VERTICAL }
  fun button(label:String, act:()->Unit) { top.addView(Button(this).apply { text=label; setOnClickListener { act() } }) }
  button("原工作台") { finish() }
  button("高精度") { loadAsset("native_full.glb") }
  button("轻量") { loadAsset("mobile.glb") }
  button("导入 GLB") { val i=Intent(Intent.ACTION_OPEN_DOCUMENT).apply { addCategory(Intent.CATEGORY_OPENABLE); type="*/*" }; startActivityForResult(i,7) }
  button("同步光照") { sync() }
  button("重置光照") { version=""; lighting(1f,1f,1f) }
  status=TextView(this).apply { text="Filament · 等待本地模型"; setTextColor(Color.WHITE); textSize=13f; setPadding(12,0,12,0) }
  top.addView(status, LinearLayout.LayoutParams(0,-2,1f))
  root.addView(top)
  surface=SurfaceView(this)
  root.addView(surface, LinearLayout.LayoutParams(-1,0,1f))
  setContentView(root)
  viewer=ModelViewer(surface)
  surface.setOnTouchListener { _, e -> viewer.onTouchEvent(e); true }
  val engine=viewer.engine
  ibl=IndirectLight.Builder().irradiance(1,floatArrayOf(0.65f,0.68f,0.72f)).intensity(18000f).build(engine)
  viewer.scene.indirectLight=ibl
  viewer.scene.skybox=Skybox.Builder().color(0.017f,0.02f,0.027f,1f).build(engine)
  viewer.view.ambientOcclusion=View.AmbientOcclusion.SSAO
  viewer.view.antiAliasing=View.AntiAliasing.FXAA
  viewer.view.renderQuality=viewer.view.renderQuality.apply { hdrColorBuffer=View.QualityLevel.HIGH }
  viewer.view.dynamicResolutionOptions=viewer.view.dynamicResolutionOptions.apply { enabled=false }
  viewer.view.multiSampleAntiAliasingOptions=viewer.view.multiSampleAntiAliasingOptions.apply { enabled=true; sampleCount=4 }
  addLight(-0.6f,-0.45f,-0.5f,23000f)
  addLight(0.4f,-0.5f,0.7f,28000f)
  val saved=File(filesDir,"character.glb")
  if(saved.exists()) load(saved) else loadAsset("native_full.glb")
 }
 private fun loadAsset(name:String) {
  try {
   val dst=File(cacheDir,name)
   if(!dst.exists()) {
    val temp=File(cacheDir,name+".tmp")
    assets.open(name).use { input -> temp.outputStream().use { output -> input.copyTo(output) } }
    require(temp.renameTo(dst))
   }
   load(dst)
  } catch(e:Exception) { status.text="内置模型加载失败："+e.message }
 }
 private fun addLight(x:Float,y:Float,z:Float,power:Float) {
  val id=EntityManager.get().create()
  LightManager.Builder(LightManager.Type.DIRECTIONAL).color(1f,1f,1f).intensity(power).direction(x,y,z).castShadows(false).build(viewer.engine,id)
  viewer.scene.addEntity(id)
 }
 private fun lighting(e:Float,k:Float,a:Float) {
  viewer.camera.setExposure(16f,1f/125f,100f*e)
  val lm=viewer.engine.lightManager
  lm.setIntensity(lm.getInstance(viewer.light),65000f*k)
  ibl.intensity=18000f*a
 }
 private fun load(f:File) {
  try {
   val n=f.length(); require(n in 20L..150_000_000L)
   val b=ByteBuffer.allocateDirect(n.toInt()).order(ByteOrder.LITTLE_ENDIAN)
   f.inputStream().channel.use { ch -> while(b.hasRemaining()) { if(ch.read(b)<0) error("文件不完整") } }
   b.flip(); require(b.getInt(0)==0x46546c67); require(b.getInt(4)==2); require(b.getInt(8)==n.toInt())
   viewer.loadModelGlb(b); viewer.transformToUnitCube(); status.text="Filament · 已导入"
  } catch(e:Exception) { status.text="加载失败："+e.message }
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
    runOnUiThread { if(!isDestroyed) load(dst) }
   } catch(e:Exception) { tmp.delete(); runOnUiThread { status.text="导入失败："+e.message } }
  }.start()
 }
 private fun sync() {
  if(checking) return
  checking=true
  Thread {
   try {
    val c=URL("https://xinminyu168-spec.github.io/starling-3d-studio/manifest.json").openConnection() as HttpsURLConnection
    c.connectTimeout=8000; c.readTimeout=8000; c.useCaches=false; c.instanceFollowRedirects=false
    val text=try { require(c.responseCode==200); c.inputStream.bufferedReader().use { it.readText().also { s -> require(s.length<32768) } } } finally { c.disconnect() }
    val j=JSONObject(text); val v=j.getString("version"); val p=j.getJSONObject("params")
    val e=p.optDouble("exposure",1.0).coerceIn(0.5,1.7).toFloat()
    val k=p.optDouble("key",1.0).coerceIn(0.0,2.0).toFloat()
    val a=p.optDouble("ambient",1.0).coerceIn(0.0,2.0).toFloat()
    runOnUiThread { checking=false; if(!isDestroyed&&version!=v) { lighting(e,k,a); version=v; status.text="已同步光照："+v } }
   } catch(e:Exception) { runOnUiThread { checking=false } }
  }.start()
 }
 override fun onResume() { super.onResume(); active=true; frames.postFrameCallback(ticker); sync() }
 override fun onPause() { active=false; frames.removeFrameCallback(ticker); super.onPause() }
}
EOF
# Avoid android.view.View name conflict with Filament View.
sed -i 's/\bView\./com.google.android.filament.View./g' app/src/main/java/com/starling/filament/MainActivity.kt
cat > app/src/main/java/com/starling/filament/StudioActivity.kt <<'EOF'
package com.starling.filament
import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.graphics.Color
import android.view.Gravity
import android.view.WindowManager
import android.webkit.WebView
import android.widget.Button
import android.widget.FrameLayout

class StudioActivity : Activity() {
 private lateinit var web: WebView
 private lateinit var updates: AppUpdates
 override fun onCreate(savedInstanceState:Bundle?) {
  super.onCreate(savedInstanceState)
  window.setFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN,WindowManager.LayoutParams.FLAG_FULLSCREEN)
  window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
  updates=AppUpdates(this)
  val frame=FrameLayout(this)
  web=WebView(this)
  web.settings.javaScriptEnabled=true
  web.settings.domStorageEnabled=true
  web.settings.allowFileAccessFromFileURLs=true
  web.settings.allowUniversalAccessFromFileURLs=false
  frame.addView(web,FrameLayout.LayoutParams(-1,-1))
  val button=Button(this).apply {
   text="Filament 原生渲染"
   textSize=12f
   setTextColor(Color.WHITE)
   setBackgroundColor(Color.rgb(30,70,115))
   setOnClickListener { startActivity(Intent(this@StudioActivity,MainActivity::class.java)) }
  }
  val pos=FrameLayout.LayoutParams(-2,-2,Gravity.BOTTOM or Gravity.START)
  pos.setMargins(8,0,0,36)
  frame.addView(button,pos)
  val check=Button(this).apply { text="检查更新"; textSize=12f; setOnClickListener { updates.check(true) } }
  frame.addView(check,FrameLayout.LayoutParams(-2,-2,Gravity.BOTTOM or Gravity.END).apply { setMargins(0,0,8,36) })
  setContentView(frame)
  web.loadUrl("file:///android_asset/viewer.html")
 }
 override fun onPause(){updates.stop();web.onPause();super.onPause()}
 override fun onResume(){super.onResume();web.onResume();updates.start() }
 override fun onDestroy(){web.destroy();super.onDestroy()}
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
 private val base="https://xinminyu168-spec.github.io/starling-3d-studio/"
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
  require(u.host=="xinminyu168-spec.github.io" && u.path.startsWith("/starling-3d-studio/"))
  return (u.openConnection() as HttpsURLConnection).apply{connectTimeout=15000;readTimeout=30000;instanceFollowRedirects=false;useCaches=false}
 }
 private fun manifest():JSONObject{
  val c=connect(base+"app-update.json")
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
 fun check(manual:Boolean){
  if(busy){if(manual)notify("正在检查或下载更新");return}
  busy=true
  if(manual)notify("正在检查程序版本…")
  Thread{
   try{
    val j=manifest()
    val v=j.optLong("versionCode",0)
    if(!j.optBoolean("enabled",false)||v<=version(installed())){handler.post{busy=false;if(manual)notify("暂无可安装的新程序版本")};return@Thread}
    val expected=j.getString("sha256").lowercase();require(expected.matches(Regex("[0-9a-f]{64}")))
    val size=j.getLong("size");require(size in 1L..900_000_000L)
    val url=j.getString("url")
    val dir=File(activity.filesDir,"updates").apply{mkdirs()}
    val out=File(dir,"update-"+v+".apk")
    fun hash(f:File):String{val md=MessageDigest.getInstance("SHA-256");f.inputStream().use{val b=ByteArray(65536);while(true){val n=it.read(b);if(n<0)break;md.update(b,0,n)}};return hex(md.digest())}
    if(!out.exists()||out.length()!=size||hash(out)!=expected){
     require(dir.usableSpace>size+20_000_000L){"存储空间不足"}
     handler.post{notify("发现新版本，正在下载")}
     val temp=File(dir,"update-"+v+".part")
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
    handler.post{busy=false;if(!activity.isFinishing&&!activity.isDestroyed&&(manual||prompted!=v)&&running){prompted=v;showInstall(out,v)}}
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
    try{activity.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri,"application/vnd.android.package-archive").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))}
    catch(e:Exception){prompted=0L;notify("无法启动系统安装器")}
   }
  }.show()
 }
}
EOF
