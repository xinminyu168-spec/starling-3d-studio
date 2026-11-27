#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p app/src/main/java/com/starling/filament app/src/main/assets
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
  applicationId 'com.starling.filament'
  minSdk 26
  targetSdk 35
  versionCode 30
  versionName '3.0-alpha'
  ndk { abiFilters 'arm64-v8a' }
 }
 compileOptions { sourceCompatibility JavaVersion.VERSION_17; targetCompatibility JavaVersion.VERSION_17 }
 kotlinOptions { jvmTarget = '17' }
}
dependencies {
 implementation 'com.google.android.filament:filament-android:1.56.0'
 implementation 'com.google.android.filament:gltfio-android:1.56.0'
 implementation 'com.google.android.filament:filament-utils-android:1.56.0'
}
EOF
cat > app/src/main/AndroidManifest.xml <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
 <uses-permission android:name="android.permission.INTERNET"/>
 <uses-feature android:glEsVersion="0x00030000" android:required="true"/>
 <application android:label="星灵 3D 原生版" android:theme="@android:style/Theme.Material.NoActionBar" android:allowBackup="false" android:usesCleartextTraffic="false" android:largeHeap="true">
  <activity android:name=".MainActivity" android:exported="true" android:configChanges="orientation|screenSize|keyboardHidden" android:screenOrientation="sensorLandscape">
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
  button("导入高精度 GLB") { val i=Intent(Intent.ACTION_OPEN_DOCUMENT).apply { addCategory(Intent.CATEGORY_OPENABLE); type="*/*" }; startActivityForResult(i,7) }
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
  if(saved.exists()) load(saved)
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
