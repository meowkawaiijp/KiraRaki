#include "Performance.hpp"
#include "Contours.hpp"
#include <cassert>
#include <cstring>
#include <iostream>
#include <vector>
int main() {
    kira::AdaptiveRender a;
    for (int i=0;i<7;++i) a.observe(35,30,true);
    assert(a.level()==0);
    a.observe(35,30,true);
    assert(a.level()==1);
    for (int i=0;i<100;++i) a.observe(40,30,true);
    assert(a.level()==6 && a.profile(false).width==320);
    assert(a.profile(true).width==960 && a.visionInterval(true,true,500)==0);
    assert(a.visionInterval(false,true,1000)==1.5);
    for (int i=0;i<1500;++i) a.observe(5,0,true);
    assert(a.level()==0);
    a.observe(50,50,false);
    assert(a.level()==0);
    kira::RollingSamples<4> v;
    for(double x : {1.,2.,3.,4.,5.}) v.push(x);
    assert(v.size()==4 && v.mean()==3.5 && v.p95()==5);
    v.clear(); assert(v.mean()==0 && v.p95()==0);
    constexpr int w=384,h=216;
    std::vector<kira::Feature> f(w*h);
    std::vector<uint8_t> mask(w*h);
    kira::Contours cpu, gpu, fallback;
    kira::Parameters p;
    for(int frame=0;frame<8;++frame) {
        for(int y=0;y<h;++y) for(int x=0;x<w;++x) {
            int i=y*w+x;
            bool line=x>4 && x<w-4 && y>4 && y<h-4 && ((y-frame)%18==0);
            f[i]=line ? kira::Feature{.9f,.8f,0,0,0,1,0,0} : kira::Feature{};
            mask[i]=i%7==0 ? 2 : uint8_t(line);
        }
        auto a=cpu.update(f.data(),w,h,1920,1080,frame/30.,p);
        auto b=gpu.update(f.data(),w,h,1920,1080,frame/30.,p,mask.data());
        std::vector<uint8_t> uncertain(w*h,2);
        auto c=fallback.update(f.data(),w,h,1920,1080,frame/30.,p,uncertain.data());
        assert(!a.empty() && a.size()==b.size() && a.size()==c.size());
        assert(std::memcmp(a.data(),b.data(),a.size()*sizeof(kira::Vertex))==0);
        assert(std::memcmp(a.data(),c.data(),a.size()*sizeof(kira::Vertex))==0);
    }
    std::cout<<"Adaptive controller, rolling metrics and GPU classification fallback passed\n";
}
