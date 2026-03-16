import csv
import math
import os
import config

# 全域快取變數
_camera_cache = None
CUSTOM_CAMERA_FILE = 'custom_cameras.csv'

def haversine(lat1, lon1, lat2, lon2):
    """計算兩點間的 GPS 直線距離 (km)"""
    R = 6371.0
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = math.sin(dlat / 2)**2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon / 2)**2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return R * c

def load_camera_data():
    """ 載入測速照相資料至記憶體快取 """
    global _camera_cache
    if _camera_cache is not None:
        return _camera_cache
    
    _camera_cache = []
    try:
        with open('camera_data.csv', mode='r', encoding='utf-8-sig') as f:
            reader = csv.DictReader(f)
            for row in reader:
                try:
                    # 支援多種 CSV 欄位名稱
                    lon_val = row.get('Longitude') or row.get('經度') or row.get('Lon') or row.get('經度(WGS84)') or 0
                    lat_val = row.get('Latitude') or row.get('緯度') or row.get('Lat') or row.get('緯度(WGS84)') or 0
                    limit_val = row.get('limit') or row.get('限速') or row.get('速限') or row.get('速限(公里/小時)') or "未知"
                    name_val = row.get('Address') or row.get('設置地點') or row.get('地點') or row.get('裝設地點') or "未知地點"
                    direct_val = row.get('direct') or row.get('行車方向') or ""

                    if float(lon_val) == 0 or float(lat_val) == 0:
                        continue

                    _camera_cache.append({
                        'lon': float(lon_val),
                        'lat': float(lat_val),
                        'limit': limit_val,
                        'name': name_val,
                        'direction': direct_val
                    })
                except (ValueError, TypeError):
                    continue
        print(f"✅ 測速照相資料快取完畢，共 {len(_camera_cache)} 筆。")
    except Exception as e:
        print(f"❌ 載入測速照相資料失敗: {e}")
    
    # 載入自訂測速照相點
    if os.path.exists(CUSTOM_CAMERA_FILE):
        try:
            with open(CUSTOM_CAMERA_FILE, mode='r', encoding='utf-8') as f:
                reader = csv.DictReader(f)
                custom_count = 0
                for row in reader:
                    try:
                        _camera_cache.append({
                            'lon': float(row['lon']),
                            'lat': float(row['lat']),
                            'limit': row.get('limit', '未知'),
                            'name': row.get('name', '自訂測速點'),
                            'direction': row.get('direction', '')
                        })
                        custom_count += 1
                    except:
                        continue
            print(f"✅ 自訂測速照相點載入完畢，共 {custom_count} 筆。")
        except Exception as e:
            print(f"❌ 載入自訂測速照相點失敗: {e}")

    return _camera_cache

def add_custom_camera(lat, lon, direction, name="自訂測速點", limit="未知"):
    """ 儲存自訂測速照相點 """
    global _camera_cache
    file_exists = os.path.exists(CUSTOM_CAMERA_FILE)
    
    try:
        with open(CUSTOM_CAMERA_FILE, mode='a', encoding='utf-8', newline='') as f:
            fieldnames = ['lat', 'lon', 'direction', 'name', 'limit']
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            
            if not file_exists:
                writer.writeheader()
            
            writer.writerow({
                'lat': lat,
                'lon': lon,
                'direction': direction,
                'name': name,
                'limit': limit
            })
        
        # 強制清空快取以便下次重新載入
        _camera_cache = None
        return True
    except Exception as e:
        print(f"❌ 儲存自訂測速點失敗: {e}")
        return False

class SpeedCameraManager:
    """測速照相管理類別 - 支援軌跡向量判斷"""
    
    def __init__(self):
        self.cameras = load_camera_data()
    
    def calculate_bearing(self, lat1, lon1, lat2, lon2):
        """計算兩點之間的方位角 (0-360度)"""
        lat1_rad = math.radians(lat1)
        lat2_rad = math.radians(lat2)
        dlon_rad = math.radians(lon2 - lon1)
        
        x = math.sin(dlon_rad) * math.cos(lat2_rad)
        y = math.cos(lat1_rad) * math.sin(lat2_rad) - \
            math.sin(lat1_rad) * math.cos(lat2_rad) * math.cos(dlon_rad)
        
        bearing_rad = math.atan2(x, y)
        bearing = (math.degrees(bearing_rad) + 360) % 360
        return bearing
    
    def bearing_to_direction(self, bearing):
        """將方位角轉換為方向字串"""
        if bearing is None: return None
        if (bearing >= 337.5) or (bearing < 22.5): return 'N'
        elif 22.5 <= bearing < 67.5: return 'NE'
        elif 67.5 <= bearing < 112.5: return 'E'
        elif 112.5 <= bearing < 157.5: return 'SE'
        elif 157.5 <= bearing < 202.5: return 'S'
        elif 202.5 <= bearing < 247.5: return 'SW'
        elif 247.5 <= bearing < 292.5: return 'W'
        else: return 'NW'
    
    def match_camera_direction(self, user_direction, camera_direction, camera_name="", user_heading=None):
        """
        判斷使用者行進方向是否符合測速照相的拍攝方向
        """
        # 0. 數位航向判定 (自訂點或精確資料專用)
        if camera_direction and str(camera_direction).replace('.', '', 1).isdigit():
            try:
                cam_bearing = float(camera_direction)
                if user_heading is not None:
                    diff = abs(user_heading - cam_bearing)
                    if diff > 180: diff = 360 - diff
                    # 如果夾角小於 45 度，視為方向吻合
                    return diff < 45
            except (ValueError, TypeError):
                pass

        if not user_direction:
            return True
        
        full_direction = f"{camera_direction} {camera_name}".lower()
        
        # 0. 絕對防呆機制：如果名稱明確寫了「北向」且你在往南開，直接擋掉
        # 這可以解決國道/快速道路最常見的誤判
        if '北向' in camera_name and user_direction in ['S', 'SE', 'SW']:
            return False
        if '南向' in camera_name and user_direction in ['N', 'NE', 'NW']:
            return False
        if '東向' in camera_name and user_direction in ['W', 'NW', 'SW']:
            return False
        if '西向' in camera_name and user_direction in ['E', 'NE', 'SE']:
            return False

        # 1. 雙向判定
        if '雙向' in full_direction or 'both' in full_direction:
            return True
            
        # 2. 複合方向判定 (例如：北向南、北往南 -> 實際上是往南)
        if any(x in full_direction for x in ['北向南', '北往南', '北至南']):
            return user_direction in ['S', 'SE', 'SW']
        if any(x in full_direction for x in ['南向北', '南往北', '南至北']):
            return user_direction in ['N', 'NE', 'NW']
        if any(x in full_direction for x in ['東向西', '東往西', '東至西']):
            return user_direction in ['W', 'NW', 'SW']
        if any(x in full_direction for x in ['西向東', '西往東', '西至東']):
            return user_direction in ['E', 'NE', 'SE']

        # 3. 單一方向關鍵字判定
        if any(x in full_direction for x in ['北向', '北上', '往北', 'north']):
            return user_direction in ['N', 'NE', 'NW']
        if any(x in full_direction for x in ['南向', '南下', '往南', 'south']):
            return user_direction in ['S', 'SE', 'SW']
        if any(x in full_direction for x in ['東向', '東行', '往東', 'east']):
            return user_direction in ['E', 'NE', 'SE']
        if any(x in full_direction for x in ['西向', '西行', '往西', 'west']):
            return user_direction in ['W', 'NW', 'SW']
        
        # 4. 無法識別方向，採取寬鬆策略
        return True
    
    def check_camera_by_trajectory(self, points_list, search_radius_km=None):
        """使用軌跡向量判斷最近的測速照相"""
        if search_radius_km is None:
            search_radius_km = config.CAMERA_SEARCH_RADIUS
            
        if not points_list or len(points_list) < 2:
            return None
        
        # 第一點(最舊) 與 最後一點(最新)
        first_point = points_list[0]
        last_point = points_list[-1]
        user_lat = last_point['lat']
        user_lon = last_point['lon']
        
        # 計算移動距離與方向
        move_distance = haversine(first_point['lat'], first_point['lon'], last_point['lat'], last_point['lon'])
        
        user_heading = None
        user_direction = None
        
        # 門檻設為 0.005 km (5公尺)，避免靜止時飄移導致方向亂跳
        if move_distance >= 0.005:
            user_heading = self.calculate_bearing(first_point['lat'], first_point['lon'], last_point['lat'], last_point['lon'])
            user_direction = self.bearing_to_direction(user_heading)
            print(f"🧭 軌跡計算: 距離={move_distance:.4f}km, 角度={user_heading:.1f}°, 方向={user_direction}")
        else:
            print(f"⚠️ 移動距離過短 ({move_distance:.4f}km)，無法判斷方向")

        nearest_cam = None
        min_dist = search_radius_km
        
        for cam in self.cameras:
            # 1. 距離過濾：找出軌跡中與相機的最近距離
            # (因為車子可能剛經過相機，最新點的距離反而變遠，所以要檢查整個軌跡)
            min_dist_in_trajectory = float('inf')
            
            for point in points_list:
                d = haversine(point['lat'], point['lon'], cam['lat'], cam['lon'])
                if d < min_dist_in_trajectory:
                    min_dist_in_trajectory = d
            
            dist = min_dist_in_trajectory
            
            if dist > min_dist:
                continue
            
            # 2. 角度過濾 (Angle Check)
            # 只有當我們能確定使用者方向時才進行
            pass_angle_check = True
            
            if user_heading is not None:
                # 計算「目前位置」到「相機」的方位角
                bearing_to_cam = self.calculate_bearing(user_lat, user_lon, cam['lat'], cam['lon'])
                
                # 計算夾角差異
                angle_diff = abs(bearing_to_cam - user_heading)
                if angle_diff > 180: angle_diff = 360 - angle_diff
                
                print(f"📐 相機 [{cam['name']}] 檢查: User行進={user_heading:.1f}°, User->Cam方位={bearing_to_cam:.1f}°, 夾角={angle_diff:.1f}°")
                
                # 嚴格過濾：如果夾角 > 80度，代表相機在側面或後方，絕對不可能拍到 (除非是雙向)
                # 您的案例：User往南(225°)，Cam在北(0°)，夾角 > 130°，這裡就會被擋下
                if angle_diff > 80:
                    print(f"❌ [角度不符] 夾角過大 ({angle_diff:.1f}° > 80°)")
                    pass_angle_check = False
                
                # 3. 名稱與方向字串過濾 (Direction String Match)
                if pass_angle_check:
                    if not self.match_camera_direction(user_direction, cam['direction'], cam['name'], user_heading):
                        print(f"❌ [方向不符] User方向 {user_direction} vs 相機 {cam['direction']}")
                        pass_angle_check = False

            if not pass_angle_check:
                continue

            # 4. 找到符合條件的相機
            if dist < min_dist:
                min_dist = dist
                
                # 判斷速限是否為未知
                limit_val = cam['limit']
                if limit_val == '未知' or limit_val == '' or limit_val is None:
                    msg = f"前方 {round(dist*1000)} 公尺有測速照相，請小心駕駛"
                else:
                    msg = f"前方 {round(dist*1000)} 公尺有測速照相，限速 {limit_val}"
                
                nearest_cam = {
                    "name": cam['name'],
                    "limit": cam['limit'],
                    "dist_km": round(dist, 2),
                    "lat": cam['lat'],
                    "lon": cam['lon'],
                    "address": cam['name'],
                    "direct": cam['direction'],
                    "found": True,
                    "message": msg,
                    # 加入除錯資訊，方便您確認是否生效
                    "debug_user_heading": user_heading,
                    "debug_angle_diff": angle_diff if user_heading is not None else -1
                }
        
        return nearest_cam

    def get_nearest_camera(self, user_lat, user_lon, direction=None, prev_lat=None, prev_lon=None, search_radius_km=1.5):
        return get_nearest_camera(user_lat, user_lon, direction, prev_lat, prev_lon)

def get_nearest_camera(user_lat, user_lon, direction=None, prev_lat=None, prev_lon=None):
    # 舊版函式保留作為備援
    return None