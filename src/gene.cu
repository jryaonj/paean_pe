#include <sys/stat.h>
#include <iomanip>
#include <iostream>
#include "bin.cuh"
#include "bin_kernel.cuh"
#include "parse.cuh"

#include <thrust/device_ptr.h>
#include <thrust/device_vector.h>
#include <thrust/execution_policy.h>
#include <thrust/functional.h>
#include <thrust/gather.h>
#include <thrust/sort.h>
#include <thrust/tuple.h>

//#include <numeric>
//#include <parallel/algorithm>
#include "cub.cuh"
int32_t nextPow2(int32_t x)
{
    --x;
    x |= x >> 1;
    x |= x >> 2;
    x |= x >> 4;
    x |= x >> 8;
    x |= x >> 16;
    return ++x;
}
__inline__ void h_setNoneZero(uint32_t *bitmap, uint32_t N)
{
    // bitmap[N >> 5] |= (0x80000000 >> (N & 31));
    bitmap[N >> 5] |= (0x80000000 >> (N & 31));
}
__inline__ void h_setNoneZeroRoll(uint32_t *bitmap, uint32_t start,
                                  uint32_t end)
{
    //#pragma unroll
    for (uint32_t i = start; i < end; i++) {
        h_setNoneZero(bitmap, i);
    }
}

__inline__ uint32_t h_popbuf(uint32_t *bitmap, uint32_t N)
{
    uint32_t sum;
    sum = 0;
    //#pragma unroll
    for (uint32_t i = 0; i < N; i++) {
        // sum += __popc(bitmap[i]);
        sum += __builtin_popcount(bitmap[i]);
    }
    return sum;
}
struct {
    bool operator()(Junction a, Junction b) const
    {
        return a.start_ < b.start_;
    }
} customLess;

void junctionSort(read_core_t &t)
{
    Junction jct[t.junctionCount];
    for (int32_t i = 0; i < t.junctionCount; i++) {
        jct[i].start_ = t.junctions[i].start_;
        jct[i].end_ = t.junctions[i].end_;
    }
    std::sort(jct, jct + t.junctionCount, customLess);
    for (int32_t i = 0; i < t.junctionCount; i++) {
        t.junctions[i].start_ = jct[i].start_;
        t.junctions[i].end_ = jct[i].end_;
    }
}
void modify_bin_length_host(h_Bins d_bins, int32_t *d_read2bin_start,
                            int32_t *d_read2bin_end, int32_t numOfRead,
                            int32_t *d_nj_read2bin_start,
                            int32_t *d_nj_read2bin_end, int32_t numOf_nj_read,
                            h_Reads d_reads, h_nj_Reads d_nj_reads,
                            int32_t *d_bin_length, int32_t numOfBin,
                            int32_t *TPM_modify)
{
    uint32_t binId;
    uint64_t bin_start, bin_end;
    uint32_t junctionCount, N, n, reads, reade;
    uint32_t *bin_buf;
    bin_buf = new uint32_t[150000];
    //#pragma omp parallel for num_threads(12)
    for (binId = 0; binId < numOfBin; binId++) {
        bin_start = d_bins.start_[binId] & (refLength - 1);
        bin_end = d_bins.end_[binId] & (refLength - 1);
        N = bin_end - bin_start + 1;
        n = N / 32 + 1;
        memset(bin_buf, 0, sizeof(uint32_t) * 150000);
        for (int32_t readId = d_read2bin_start[binId];
             readId < d_read2bin_end[binId]; readId++) {
            junctionCount = d_reads.core[readId].junctionCount;
            reads = uint32_t(d_reads.start_[readId] & (refLength - 1));
            reade = uint32_t(d_reads.end_[readId] & (refLength - 1));
            if (junctionCount) {
                read_core_t t;
                read_core_t t_filter;
                t.junctionCount = d_reads.core[readId].junctionCount;
                for (int32_t jId = 0; jId < t.junctionCount; jId++) {
                    t.junctions[jId].start_ =
                        d_reads.core[readId].junctions[jId].start_;
                    t.junctions[jId].end_ =
                        d_reads.core[readId].junctions[jId].end_;
                }

                junctionSort(t);
                for (int32_t jId = 0; jId < t.junctionCount; jId++) {
                    if (t.junctions[jId].start_ + reads - 1 - bin_start >
                            int(N + 150) or
                        t.junctions[jId].end_ + reads - 1 - bin_start >
                            (N + 150)) {
			TPM_modify[binId] += 1;
                        continue;
                    } else {
                        t_filter.junctionCount += 1;
                        t_filter.junctions[t_filter.junctionCount - 1].start_ =
                            t.junctions[jId].start_;
                        t_filter.junctions[t_filter.junctionCount - 1].end_ =
                            t.junctions[jId].end_;
                    }
                }
                // default junction pattern on reads
                if (t_filter.junctionCount) {
                    for (int32_t jId = 0; jId <= t_filter.junctionCount;
                         jId++) {
                        if (jId == 0) {
                            uint32_t s = reads - bin_start;
                            uint32_t e = t_filter.junctions[jId].start_ +
                                         reads - 1 - bin_start;
                            if (e > N + 150 or s > N + 150) {
                                // printf("TYPE\tbinId\treadId\tjId\ts\te\tN\n");
                                // printf("TYPE1\t%d\t%d\t%d\t%d\t%d\t%d\n",
                                // binId,
                                //  readId, jId, s, e, N);
                                e = N;
                            }
                            h_setNoneZeroRoll(bin_buf, s, e);
                        }
                        if (jId == t_filter.junctionCount) {
                            uint32_t s = t_filter.junctions[jId - 1].end_ +
                                         reads - 1 - bin_start;

                            uint32_t e = reade - bin_start;
                            if (e > N + 150 or s > N + 150) {
                                // printf("TYPE\tbinId\treadId\tjId\ts\te\tN\n");
                                // printf("TYPE2\t%d\t%d\t%d\t%d\t%d\t%d\n",
                                // binId,
                                //        readId, jId, s, e, N);
                                e = N;
                            }
                            h_setNoneZeroRoll(bin_buf, s, e);
                        }
                        if (jId != 0 and jId != t_filter.junctionCount) {
                            uint32_t s = t_filter.junctions[jId - 1].end_ +
                                         reads - 1 - bin_start;
                            uint32_t e = t_filter.junctions[jId].start_ +
                                         reads - 1 - bin_start;
                            if (e > N + 150 or s > N + 150) {
                                // printf("TYPE\tbinId\treadId\tjId\ts\te\tN\n");
                                // printf("TYPE3\t%d\t%d\t%d\t%d\t%d\t%d\n", binId,
                                //        readId, jId, s, e, N);
                                e = N;
                            }
                            h_setNoneZeroRoll(bin_buf, s, e);
                        }
                    }
                }
            }
        }
        //#pragma unroll
        for (int32_t readId = d_nj_read2bin_start[binId];
             readId < d_nj_read2bin_end[binId]; readId++) {
            reads = uint32_t(d_nj_reads.start_[readId] & (refLength - 1));
            reade = uint32_t(d_nj_reads.end_[readId] & (refLength - 1));
            h_setNoneZeroRoll(bin_buf, reads - bin_start, reade - bin_start);
        }
        d_bin_length[binId] = h_popbuf(bin_buf, n);
    }
    delete[] bin_buf;
}

d_Reads gpu_chipMallocRead(h_Reads &h_reads, int32_t numOfRead)
{
    d_Reads d_reads;
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&(d_reads.start_), sizeof(uint64_t) * numOfRead));
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&(d_reads.end_), sizeof(uint64_t) * numOfRead));
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&(d_reads.strand), sizeof(uint8_t) * numOfRead));
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&(d_reads.core), sizeof(read_core_t) * numOfRead));

    CUDA_SAFE_CALL(cudaMemcpy(d_reads.start_, h_reads.start_.data(),
                              sizeof(uint64_t) * numOfRead,
                              cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(d_reads.end_, h_reads.end_.data(),
                              sizeof(uint64_t) * numOfRead,
                              cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(d_reads.strand, h_reads.strand.data(),
                              sizeof(uint8_t) * numOfRead,
                              cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(d_reads.core, h_reads.core.data(),
                              sizeof(read_core_t) * numOfRead,
                              cudaMemcpyHostToDevice));
    // std::memcpy(d_reads.start_, h_reads.start_.data(), sizeof(uint64_t) *
    // numOfRead); std::memcpy(d_reads.end_, h_reads.end_.data(),
    // sizeof(uint64_t) * numOfRead); std::memcpy(d_reads.strand,
    // h_reads.strand.data(), sizeof(uint32_t) * numOfRead);
    // std::memcpy(d_reads.core, h_reads.core.data(), sizeof(read_core_t) *
    // numOfRead);

    return d_reads;
}

d_nj_Reads gpu_chipMalloc_njRead(h_nj_Reads &h_nj_reads, int32_t numOf_nj_Read)
{
    d_nj_Reads d_nj_reads;
    CUDA_SAFE_CALL(cudaMalloc((void **)&(d_nj_reads.start_),
                              sizeof(uint64_t) * numOf_nj_Read));
    CUDA_SAFE_CALL(cudaMalloc((void **)&(d_nj_reads.end_),
                              sizeof(uint64_t) * numOf_nj_Read));
    CUDA_SAFE_CALL(cudaMalloc((void **)&(d_nj_reads.strand),
                              sizeof(uint8_t) * numOf_nj_Read));

    CUDA_SAFE_CALL(cudaMemcpy(d_nj_reads.start_, h_nj_reads.start_.data(),
                              sizeof(uint64_t) * numOf_nj_Read,
                              cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(d_nj_reads.end_, h_nj_reads.end_.data(),
                              sizeof(uint64_t) * numOf_nj_Read,
                              cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(d_nj_reads.strand, h_nj_reads.strand.data(),
                              sizeof(uint8_t) * numOf_nj_Read,
                              cudaMemcpyHostToDevice));
    // std::memcpy(d_reads.start_, h_reads.start_.data(), sizeof(uint64_t) *
    // numOfRead); std::memcpy(d_reads.end_, h_reads.end_.data(),
    // sizeof(uint64_t) * numOfRead); std::memcpy(d_reads.strand,
    // h_reads.strand.data(), sizeof(uint32_t) * numOfRead);
    // std::memcpy(d_reads.core, h_reads.core.data(), sizeof(read_core_t) *
    // numOfRead);

    return d_nj_reads;
}

d_ASEs gpu_chipMallocASE(h_ASEs &h_ases, int32_t numOfASE)
{
    d_ASEs d_ases;
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&(d_ases.start_), sizeof(uint64_t) * numOfASE));
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&(d_ases.end_), sizeof(uint64_t) * numOfASE));
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&(d_ases.strand), sizeof(uint8_t) * numOfASE));
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&(d_ases.core), sizeof(ase_core_t) * numOfASE));

    CUDA_SAFE_CALL(cudaMemcpy(d_ases.start_, h_ases.start_.data(),
                              sizeof(uint64_t) * numOfASE,
                              cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(d_ases.end_, h_ases.end_.data(),
                              sizeof(uint64_t) * numOfASE,
                              cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(d_ases.strand, h_ases.strand.data(),
                              sizeof(uint8_t) * numOfASE,
                              cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(d_ases.core, h_ases.core.data(),
                              sizeof(ase_core_t) * numOfASE,
                              cudaMemcpyHostToDevice));

    // std::memcpy(d_ases->start_, h_ases.start_.data(), sizeof(uint64_t) *
    // numOfASE); std::memcpy(d_ases->end_, h_ases.end_.data(), sizeof(uint64_t)
    // * numOfASE); std::memcpy(d_ases->strand, h_ases.strand.data(),
    // sizeof(uint32_t) * numOfASE); std::memcpy(d_ases->core,
    // h_ases.core.data(), sizeof(ase_core_t) * numOfASE);

    return d_ases;
}

d_Bins gpu_chipMallocBin(h_Bins &h_bins, int32_t numOfBin)
{
    d_Bins d_bins;
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&(d_bins.start_), sizeof(uint64_t) * numOfBin));
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&(d_bins.end_), sizeof(uint64_t) * numOfBin));
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&(d_bins.strand), sizeof(uint8_t) * numOfBin));
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&(d_bins.core), sizeof(bin_core_t) * numOfBin));

    CUDA_SAFE_CALL(cudaMemcpy(d_bins.start_, h_bins.start_.data(),
                              sizeof(uint64_t) * numOfBin,
                              cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(d_bins.end_, h_bins.end_.data(),
                              sizeof(uint64_t) * numOfBin,
                              cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(d_bins.strand, h_bins.strand.data(),
                              sizeof(uint8_t) * numOfBin,
                              cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(d_bins.core, h_bins.core.data(),
                              sizeof(bin_core_t) * numOfBin,
                              cudaMemcpyHostToDevice));

    // std::memcpy(d_bins->start_, h_bins.start_.data(), sizeof(uint64_t) *
    // numOfBin); std::memcpy(d_bins->end_, h_bins.end_.data(), sizeof(uint64_t)
    // * numOfBin); std::memcpy(d_bins->strand, h_bins.strand.data(),
    // sizeof(uint32_t) * numOfBin); std::memcpy(d_bins->core,
    // h_bins.core.data(), sizeof(bin_core_t) * numOfBin);

    return d_bins;
}

void HandleBin(h_Bins &h_bins, h_Reads &h_reads, h_nj_Reads &h_nj_reads,
               h_ASEs &h_ases)
{
    int32_t numOfBin = int32_t(h_bins.start_.size());
    int32_t numOfRead = int32_t(h_reads.start_.size());
    int32_t numOfASE = int32_t(h_ases.start_.size());

    int32_t numOf_nj_Read = int32_t(h_nj_reads.start_.size());

    std::cout << "numOfBin: " << numOfBin << std::endl;
    std::cout << "numOfRead: " << numOfRead << std::endl;
    std::cout << "numOfASE: " << numOfASE << std::endl;

    std::cout << "numOfnjRead: " << numOf_nj_Read << std::endl;
    // compute number of thread block
    unsigned nBlock = (unsigned(numOfBin) + blockSize - 1) / blockSize;

    // copy reads to device global memory
    d_Reads d_reads = gpu_chipMallocRead(h_reads, numOfRead);
    d_nj_Reads d_nj_reads = gpu_chipMalloc_njRead(h_nj_reads, numOf_nj_Read);

    std::cout << "starting sorting reads..." << std::endl;
    thrust::device_ptr<uint64_t> d_starts =
        thrust::device_pointer_cast(d_reads.start_);
    thrust::device_ptr<uint64_t> d_ends =
        thrust::device_pointer_cast(d_reads.end_);
    thrust::device_ptr<uint8_t> d_strands =
        thrust::device_pointer_cast(d_reads.strand);
    thrust::device_ptr<read_core_t> d_cores =
        thrust::device_pointer_cast(d_reads.core);

    thrust::device_vector<int> d_indices((unsigned long)numOfRead);
    thrust::sequence(d_indices.begin(), d_indices.end(), 0, 1);
    thrust::stable_sort_by_key(thrust::device, d_starts, d_starts + numOfRead,
                               d_indices.begin());
    /*
    thrust::gather(thrust::device, d_indices.begin(), d_indices.end(), d_ends,
                   d_ends);
    thrust::gather(thrust::device, d_indices.begin(), d_indices.end(),
                   d_strands, d_strands);
    thrust::gather(thrust::device, d_indices.begin(), d_indices.end(), d_cores,
                   d_cores);
    */
    if (thrust::is_sorted(d_starts, d_starts + numOfRead)) {
        printf("sorted d_starts!\n");
    }

    uint32_t *ind;
    ind = new uint32_t[numOfRead];
    for (uint32_t i = 0; i < numOfRead; i++) {
        ind[i] = d_indices[i];
    }
    uint32_t *d_ind;
    cudaMalloc((void **)&d_ind, sizeof(uint32_t) * numOfRead);
    cudaMemcpy(d_ind, ind, sizeof(uint32_t) * numOfRead,
               cudaMemcpyHostToDevice);
    uint64_t *gatmp_read_e;
    uint8_t *gatmp_t;
    read_core_t *gatmp_c;
    cudaMalloc((void **)&gatmp_read_e, sizeof(uint64_t) * numOfRead);
    cudaMalloc((void **)&gatmp_t, sizeof(uint8_t) * numOfRead);
    cudaMalloc((void **)&gatmp_c, sizeof(read_core_t) * numOfRead);
    cudaMemcpy(gatmp_read_e, d_reads.end_, numOfRead * sizeof(uint64_t),
               cudaMemcpyDeviceToDevice);
    cudaMemcpy(gatmp_t, d_reads.strand, numOfRead * sizeof(uint8_t),
               cudaMemcpyDeviceToDevice);
    cudaMemcpy(gatmp_c, d_reads.core, numOfRead * sizeof(read_core_t),
               cudaMemcpyDeviceToDevice);

    unsigned nReadBlock = (unsigned(numOfRead) + blockSize - 1) / blockSize;
    gather<uint64_t><<<nReadBlock, blockSize>>>(d_ind, gatmp_read_e,
                                                d_reads.end_, numOfRead);
    gather<uint8_t>
        <<<nReadBlock, blockSize>>>(d_ind, gatmp_t, d_reads.strand, numOfRead);
    gather<read_core_t>
        <<<nReadBlock, blockSize>>>(d_ind, gatmp_c, d_reads.core, numOfRead);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());

    cudaFree(gatmp_read_e);
    cudaFree(gatmp_t);
    cudaFree(gatmp_c);
    cudaFree(d_ind);
    delete[] ind;

    std::cout << "starting sorting nj_reads..." << std::endl;
    thrust::device_ptr<uint64_t> d_nj_starts =
        thrust::device_pointer_cast(d_nj_reads.start_);
    thrust::device_ptr<uint64_t> d_nj_ends =
        thrust::device_pointer_cast(d_nj_reads.end_);
    thrust::device_ptr<uint8_t> d_nj_strands =
        thrust::device_pointer_cast(d_nj_reads.strand);

    thrust::device_vector<int> d_nj_indices((unsigned long)numOf_nj_Read);
    thrust::sequence(d_nj_indices.begin(), d_nj_indices.end(), 0, 1);
    thrust::stable_sort_by_key(thrust::device, d_nj_starts,
                               d_nj_starts + numOf_nj_Read,
                               d_nj_indices.begin());
    /*
    thrust::gather(thrust::device, d_indices.begin(), d_indices.end(), d_ends,
                   d_ends);
    thrust::gather(thrust::device, d_indices.begin(), d_indices.end(),
                   d_strands, d_strands);
    thrust::gather(thrust::device, d_indices.begin(), d_indices.end(), d_cores,
                   d_cores);
    */
    if (thrust::is_sorted(d_nj_starts, d_nj_starts + numOf_nj_Read)) {
        printf("sorted d_nj_starts!\n");
    }

    uint32_t *nj_ind;
    nj_ind = new uint32_t[numOf_nj_Read];
    for (uint32_t i = 0; i < numOf_nj_Read; i++) {
        nj_ind[i] = d_nj_indices[i];
    }
    uint32_t *d_nj_ind;
    cudaMalloc((void **)&d_nj_ind, sizeof(uint32_t) * numOf_nj_Read);
    cudaMemcpy(d_nj_ind, nj_ind, sizeof(uint32_t) * numOf_nj_Read,
               cudaMemcpyHostToDevice);
    uint64_t *gatmp_read_e_nj;
    uint8_t *gatmp_t_nj;
    cudaMalloc((void **)&gatmp_read_e_nj, sizeof(uint64_t) * numOf_nj_Read);
    cudaMalloc((void **)&gatmp_t_nj, sizeof(uint8_t) * numOf_nj_Read);
    cudaMemcpy(gatmp_read_e_nj, d_nj_reads.end_,
               numOf_nj_Read * sizeof(uint64_t), cudaMemcpyDeviceToDevice);
    cudaMemcpy(gatmp_t_nj, d_nj_reads.strand, numOf_nj_Read * sizeof(uint8_t),
               cudaMemcpyDeviceToDevice);

    gather<uint64_t><<<nReadBlock, blockSize>>>(d_nj_ind, gatmp_read_e_nj,
                                                d_nj_reads.end_, numOf_nj_Read);
    gather<uint8_t><<<nReadBlock, blockSize>>>(
        d_nj_ind, gatmp_t_nj, d_nj_reads.strand, numOf_nj_Read);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());

    cudaFree(gatmp_read_e_nj);
    cudaFree(gatmp_t_nj);
    cudaFree(d_nj_ind);
    delete[] nj_ind;

    std::cout << "end sorting nj_reads..." << std::endl;
    /*
    uint64_t *ds_read_s;
    uint64_t *ds_read_e;
    uint8_t *ds_t;
    read_core_t *ds_read_c;
    ds_read_s = new uint64_t[numOfRead];
    ds_read_e = new uint64_t[numOfRead];
    ds_read_c = new read_core_t[numOfRead];
    ds_t = new uint8_t[numOfRead];
    cudaMemcpy(ds_read_s,d_reads.start_,numOfRead*sizeof(uint64_t),cudaMemcpyDeviceToHost);
    cudaMemcpy(ds_read_e,d_reads.end_,numOfRead*sizeof(uint64_t),cudaMemcpyDeviceToHost);
    cudaMemcpy(ds_read_c,d_reads.core,numOfRead*sizeof(read_core_t),cudaMemcpyDeviceToHost);
    cudaMemcpy(ds_t,d_reads.strand,numOfRead*sizeof(uint8_t),cudaMemcpyDeviceToHost);
    FILE *p;
    p=fopen("/home/qianjiaqiang/dr.txt","w");
    for (uint32_t i=0;i<numOfRead;i++){
        fprintf(p,"%lu\t%lu\t%d\t%lu\t%lu\t%d\n",ds_read_s[i],ds_read_e[i],ds_t[i],ds_read_c[i].junctions[0].start_,ds_read_c[i].junctions[0].end_,int(d_indices[i]));
    }
    fclose(p);
    delete[] ds_read_s;
    delete[] ds_read_e;
    delete[] ds_read_c;
    delete[] ds_t;
    */

    // copy bins to device global memory
    d_Bins d_bins = gpu_chipMallocBin(h_bins, numOfBin);

    // copy ases to device global memory
    d_ASEs d_ases = gpu_chipMallocASE(h_ases, numOfASE);
    // auxiliary array
    Assist *d_assist_reads;
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_assist_reads, sizeof(Assist) * numOfBin));
    int32_t *d_read2bin_start;
    int32_t *d_read2bin_end;
    int32_t *d_nj_read2bin_start;
    int32_t *d_nj_read2bin_end;

    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_read2bin_start, sizeof(int32_t) * numOfBin));
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_read2bin_end, sizeof(int32_t) * numOfBin));
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_nj_read2bin_start, sizeof(int32_t) * numOfBin));
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_nj_read2bin_end, sizeof(int32_t) * numOfBin));

    // assign reads to bins
    std::cout << "starting assign reads..." << std::endl;
    gpu_assign_nj_read_kernel<<<nBlock, blockSize>>>(
        d_bins, numOfBin, d_nj_reads, numOfRead, d_assist_reads,
        d_nj_read2bin_start, d_nj_read2bin_end);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    gpu_assign_read_kernel<<<nBlock, blockSize>>>(
        d_bins, numOfBin, d_reads, numOfRead, d_assist_reads, d_read2bin_start,
        d_read2bin_end);

    CUDA_SAFE_CALL(cudaDeviceSynchronize());

    float *d_tempTPM, *d_tpmCounter;
    // d_tempTPM
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_tempTPM, numOfBin * sizeof(float)));
    CUDA_SAFE_CALL(cudaMemset(d_tempTPM, 0, numOfBin * sizeof(float)));
    // d_tpmCounter
    int32_t tpmSize = (nextPow2(nBlock) + 1) / 2;
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_tpmCounter, tpmSize * sizeof(float)));
    CUDA_SAFE_CALL(cudaMemset(d_tpmCounter, 0, tpmSize * sizeof(float)));
    // count temp
    float *tpmStore;
    tpmStore = new float[numOfBin];
    float *d_tpmStore;
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_tpmStore, numOfBin * sizeof(float)));

    std::cout << "starting count tpm..." << std::endl;
    gpu_count_tempTPM<<<nBlock, blockSize>>>(d_bins, numOfBin, d_tempTPM);
    reduceSinglePass(static_cast<int>(numOfBin), blockSize,
                     static_cast<int>(tpmSize), d_tempTPM, d_tpmCounter);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    gpu_count_TPM<<<nBlock, blockSize>>>(d_bins, numOfBin, d_tempTPM,
                                         d_tpmCounter, d_tpmStore);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    CUDA_SAFE_CALL(cudaMemcpy(tpmStore, d_tpmStore, numOfBin * sizeof(float),
                              cudaMemcpyDeviceToHost));

    // auxiliary array
    Assist *d_assist_ases;
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_assist_ases, sizeof(Assist) * numOfBin));
    int32_t *d_bin2ase;
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_bin2ase, sizeof(int32_t) * numOfASE));
    std::cout << "starting assign ases..." << std::endl;
    // assign ases to bins
    gpu_assign_ASE_kernel<<<nBlock, blockSize>>>(
        d_bins, numOfBin, d_ases, numOfASE, d_assist_ases, d_bin2ase);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());

    // auxiliary array
    Assist *d_assist_read_ases;
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_assist_read_ases, sizeof(Assist) * numOfASE));
    ASECounter *ACT;
    CUDA_SAFE_CALL(cudaMalloc((void **)&ACT, sizeof(ASECounter) * numOfASE));
    // compute number of thread block
    nBlock = (unsigned(numOfASE) + blockSize - 1) / blockSize;
    // assign reads to ases
    std::cout << "starting assign reads to ases..." << std::endl;
    // gpu_assign_read_ASE_kernel<<<nBlock, blockSize>>>(
    //   d_ases, numOfASE, d_reads, numOfRead, d_assist_read_ases, ACT);
    gpu_assign_nj_read_ASE_kernel<<<nBlock, blockSize>>>(
        d_ases, numOfASE, d_nj_reads, numOf_nj_Read, d_assist_read_ases, ACT,
        d_bin2ase, d_nj_read2bin_start, d_nj_read2bin_end);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    gpu_assign_read_ASE_kernel2<<<nBlock, blockSize>>>(
        d_ases, numOfASE, d_reads, numOfRead, d_assist_read_ases, ACT,
        d_bin2ase, d_read2bin_start, d_read2bin_end);

    CUDA_SAFE_CALL(cudaDeviceSynchronize());

    ASEPsi *d_ase_psi;
    size_t psiSize = sizeof(ASEPsi) * numOfASE;
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_ase_psi, psiSize));
    // count psi
    std::cout << "starting count psi..." << std::endl;
    gpu_count_PSI<<<nBlock, blockSize>>>(d_ases, numOfASE, d_ase_psi, ACT);

    CUDA_SAFE_CALL(cudaDeviceSynchronize());

    // psi
    ASEPsi *h_ase_psi = (ASEPsi *)malloc(psiSize);
    CUDA_SAFE_CALL(
        cudaMemcpy(h_ase_psi, d_ase_psi, psiSize, cudaMemcpyDeviceToHost));
    // tpm
    float tpmCounter = 0;
    CUDA_SAFE_CALL(cudaMemcpy(&tpmCounter, d_tpmCounter, sizeof(float),
                              cudaMemcpyDeviceToHost));
#define BETAINV
#ifdef BETAINV
    float *psi_ub;
    float *psi_lb;
    float *d_psi_ub;
    float *d_psi_lb;
    psi_ub = new float[numOfASE];
    psi_lb = new float[numOfASE];
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_psi_ub, numOfASE * sizeof(float)));
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_psi_lb, numOfASE * sizeof(float)));
    std::cout << "starting calculating beta.inv psi..." << std::endl;
    gpu_post_PSI<<<nBlock * 4, blockSize / 4>>>(d_ase_psi, ACT, d_psi_ub,
                                                d_psi_lb, numOfASE);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    CUDA_SAFE_CALL(cudaMemcpy(psi_ub, d_psi_ub, numOfASE * sizeof(float),
                              cudaMemcpyDeviceToHost));
    CUDA_SAFE_CALL(cudaMemcpy(psi_lb, d_psi_lb, numOfASE * sizeof(float),
                              cudaMemcpyDeviceToHost));
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    cudaFree(d_psi_ub);
    cudaFree(d_psi_lb);
#endif

#define DEBUG
#ifdef DEBUG
    // ase psi
    float countIn, countOut;
    UMAP::const_iterator gid, bin;
    NMAP::const_iterator bin_id;
    countIn = countOut = 0;
    std::cout.setf(std::ios::fixed);
    std::cout << "ase_event"
              << "\t"
              << "gene_name"
              << "\t"
              << "countIn"
              << "\t"
              << "countOut"
              << "\t"
              << "psi_lb"
              << "\t"
              << "psi_ub"
              << "\t"
              << "psi"
              << "\t"
              << "tpm" << std::endl;
    for (int i = 0; i < numOfBin; i++) {
        bin_id_map.insert({h_bins.core[i].name_h, i});
    }
    for (int i = 0; i < numOfASE; i++) {
        if (h_ase_psi[i].countIn) countIn++;
        if (h_ase_psi[i].countOut) countOut++;
        gid = g_gid_map.find(h_ase_psi[i].gid_h);
        bin = g_name_map.find(h_ase_psi[i].bin_h);
        bin_id = bin_id_map.find(h_ase_psi[i].bin_h);
        std::cout << gid->second << "\t"
                  << ((bin == g_name_map.end()) ? "null" : bin->second) << "\t"
                  << std::setprecision(3) << h_ase_psi[i].countIn << "\t"
                  << h_ase_psi[i].countOut
#ifdef BETAINV
                  << "\t" << psi_lb[i] << "\t" << psi_ub[i]
#endif

                  << "\t" << h_ase_psi[i].psi << "\t"
                  << ((bin == g_name_map.end()) ? -1 : tpmStore[bin_id->second])
                  << std::endl;
    }
    std::cout << std::setprecision(3) << countIn << "\t" << std::setprecision(3)
              << countOut << std::endl;
    // tpm
    std::cout << std::setprecision(3) << "tpm count: " << tpmCounter
              << std::endl;
#endif
#ifdef BETAINV
    delete[] psi_ub;
    delete[] psi_lb;
#endif
    /*
    int32_t *h_r2b_s;
    int32_t *h_r2b_e;
    h_r2b_s = new int32_t[numOfBin];
    h_r2b_e = new int32_t[numOfBin];
    cudaMemcpy(h_r2b_s,d_read2bin_start,sizeof(int32_t)*numOfBin,cudaMemcpyDeviceToHost);
    cudaMemcpy(h_r2b_e,d_read2bin_end,sizeof(int32_t)*numOfBin,cudaMemcpyDeviceToHost);
    FILE *d;
    d = fopen("/home/qianjiaqiang/r2b.txt","w");
    for (uint32_t i=0;i<numOfBin;i++){
        fprintf(d,"%d\t%d\n",h_r2b_s[i],h_r2b_e[i]);
        }
    fclose(d);
    delete[] h_r2b_s;
    delete[] h_r2b_e;
    */

    // free memory
    std::cout << "free memory..." << std::endl;
    cudaFree(d_ase_psi);
    cudaFree(d_tempTPM);
    cudaFree(d_tpmStore);
    cudaFree(d_tpmCounter);
    cudaFree(d_assist_reads);
    cudaFree(d_assist_ases);
    cudaFree(d_assist_read_ases);
    cudaFree(d_read2bin_start);
    cudaFree(d_read2bin_end);
    cudaFree(d_nj_read2bin_start);
    cudaFree(d_nj_read2bin_end);
    cudaFree(d_bin2ase);
    delete[] tpmStore;
}

void HandleBin_cub(h_Bins &h_bins, h_Reads &h_reads, h_nj_Reads &h_nj_reads,
                   h_ASEs &h_ases)
{
    int32_t numOfBin = int32_t(h_bins.start_.size());
    int32_t numOfRead = int32_t(h_reads.start_.size());
    int32_t numOfASE = int32_t(h_ases.start_.size());

    int32_t numOf_nj_Read = int32_t(h_nj_reads.start_.size());

    std::cout << "numOfBin: " << numOfBin << std::endl;
    std::cout << "numOfRead: " << numOfRead << std::endl;
    std::cout << "numOfASE: " << numOfASE << std::endl;

    std::cout << "numOfnjRead: " << numOf_nj_Read << std::endl;
    // compute number of thread block
    unsigned nBlock = (unsigned(numOfBin) + blockSize - 1) / blockSize;

    // copy reads to device global memory
    d_Reads d_reads = gpu_chipMallocRead(h_reads, numOfRead);
    d_nj_Reads d_nj_reads = gpu_chipMalloc_njRead(h_nj_reads, numOf_nj_Read);

    std::cout << "starting sorting reads..." << std::endl;
    uint32_t *ind;
    ind = new uint32_t[numOfRead];
    // ind = std::iota(ind,ind+numOfRead,0);
    for (uint32_t i = 0; i < numOfRead; i++) {
        ind[i] = i;
    }

    uint64_t *d_start_in;
    uint32_t *d_indices_in;
    uint32_t *d_indices;
    cudaMalloc((void **)&d_start_in, sizeof(uint64_t) * numOfRead);
    cudaMalloc((void **)&d_indices_in, sizeof(uint32_t) * numOfRead);
    cudaMalloc((void **)&d_indices, sizeof(uint32_t) * numOfRead);
    cudaMemcpy(d_start_in, d_reads.start_, sizeof(uint64_t) * numOfRead,
               cudaMemcpyDeviceToDevice);
    cudaMemcpy(d_indices_in, ind, sizeof(uint32_t) * numOfRead,
               cudaMemcpyHostToDevice);
    void *d_temp_storage = NULL;
    size_t temp_storage_bytes = 0;
    cub::DeviceRadixSort::SortPairs(d_temp_storage, temp_storage_bytes,
                                    d_start_in, d_reads.start_, d_indices_in,
                                    d_indices, numOfRead);
    cudaMalloc(&d_temp_storage, temp_storage_bytes);
    cub::DeviceRadixSort::SortPairs(d_temp_storage, temp_storage_bytes,
                                    d_start_in, d_reads.start_, d_indices_in,
                                    d_indices, numOfRead);

    uint64_t *gatmp_read_e;
    uint8_t *gatmp_t;
    read_core_t *gatmp_c;
    cudaMalloc((void **)&gatmp_read_e, sizeof(uint64_t) * numOfRead);
    cudaMalloc((void **)&gatmp_t, sizeof(uint8_t) * numOfRead);
    cudaMalloc((void **)&gatmp_c, sizeof(read_core_t) * numOfRead);
    cudaMemcpy(gatmp_read_e, d_reads.end_, numOfRead * sizeof(uint64_t),
               cudaMemcpyDeviceToDevice);
    cudaMemcpy(gatmp_t, d_reads.strand, numOfRead * sizeof(uint8_t),
               cudaMemcpyDeviceToDevice);
    cudaMemcpy(gatmp_c, d_reads.core, numOfRead * sizeof(read_core_t),
               cudaMemcpyDeviceToDevice);

    unsigned nReadBlock = (unsigned(numOfRead) + blockSize - 1) / blockSize;
    gather<uint64_t><<<nReadBlock, blockSize>>>(d_indices, gatmp_read_e,
                                                d_reads.end_, numOfRead);
    gather<uint8_t><<<nReadBlock, blockSize>>>(d_indices, gatmp_t,
                                               d_reads.strand, numOfRead);
    gather<read_core_t><<<nReadBlock, blockSize>>>(d_indices, gatmp_c,
                                                   d_reads.core, numOfRead);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());

    cudaFree(gatmp_read_e);
    cudaFree(gatmp_t);
    cudaFree(gatmp_c);
    cudaFree(d_temp_storage);
    cudaFree(d_indices);
    cudaFree(d_indices_in);
    cudaFree(d_start_in);
    delete[] ind;

    std::cout << "starting sorting nj_reads..." << std::endl;

    uint32_t *nj_indices;
    nj_indices = new uint32_t[numOf_nj_Read];
    for (uint32_t i = 0; i < numOf_nj_Read; i++) {
        nj_indices[i] = i;
    }
    uint32_t *d_nj_indices;
    uint32_t *d_nj_indices_in;
    uint64_t *d_nj_start_in;

    cudaMalloc((void **)&d_nj_indices, sizeof(uint32_t) * numOf_nj_Read);
    cudaMalloc((void **)&d_nj_indices_in, sizeof(uint32_t) * numOf_nj_Read);
    cudaMalloc((void **)&d_nj_start_in, sizeof(uint64_t) * numOf_nj_Read);
    cudaMemcpy(d_nj_start_in, d_nj_reads.start_,
               sizeof(uint64_t) * numOf_nj_Read, cudaMemcpyDeviceToDevice);
    cudaMemcpy(d_nj_indices_in, nj_indices, sizeof(uint32_t) * numOf_nj_Read,
               cudaMemcpyHostToDevice);
    d_temp_storage = NULL;
    temp_storage_bytes = 0;
    cub::DeviceRadixSort::SortPairs(
        d_temp_storage, temp_storage_bytes, d_nj_start_in, d_nj_reads.start_,
        d_nj_indices_in, d_nj_indices, numOf_nj_Read);
    cudaMalloc(&d_temp_storage, temp_storage_bytes);
    cub::DeviceRadixSort::SortPairs(
        d_temp_storage, temp_storage_bytes, d_nj_start_in, d_nj_reads.start_,
        d_nj_indices_in, d_nj_indices, numOf_nj_Read);

    uint64_t *gatmp_read_e_nj;
    uint8_t *gatmp_t_nj;
    cudaMalloc((void **)&gatmp_read_e_nj, sizeof(uint64_t) * numOf_nj_Read);
    cudaMalloc((void **)&gatmp_t_nj, sizeof(uint8_t) * numOf_nj_Read);
    cudaMemcpy(gatmp_read_e_nj, d_nj_reads.end_,
               numOf_nj_Read * sizeof(uint64_t), cudaMemcpyDeviceToDevice);
    cudaMemcpy(gatmp_t_nj, d_nj_reads.strand, numOf_nj_Read * sizeof(uint8_t),
               cudaMemcpyDeviceToDevice);

    gather<uint64_t><<<nReadBlock, blockSize>>>(d_nj_indices, gatmp_read_e_nj,
                                                d_nj_reads.end_, numOf_nj_Read);
    gather<uint8_t><<<nReadBlock, blockSize>>>(
        d_nj_indices, gatmp_t_nj, d_nj_reads.strand, numOf_nj_Read);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());

    cudaFree(gatmp_read_e_nj);
    cudaFree(gatmp_t_nj);
    cudaFree(d_nj_indices);
    cudaFree(d_nj_indices_in);
    cudaFree(d_nj_start_in);
    cudaFree(d_temp_storage);
    delete[] nj_indices;

    std::cout << "end sorting nj_reads..." << std::endl;
    /*
    uint64_t *ds_read_s;
    uint64_t *ds_read_e;
    uint8_t *ds_t;
    read_core_t *ds_read_c;
    ds_read_s = new uint64_t[numOfRead];
    ds_read_e = new uint64_t[numOfRead];
    ds_read_c = new read_core_t[numOfRead];
    ds_t = new uint8_t[numOfRead];
    cudaMemcpy(ds_read_s,d_reads.start_,numOfRead*sizeof(uint64_t),cudaMemcpyDeviceToHost);
    cudaMemcpy(ds_read_e,d_reads.end_,numOfRead*sizeof(uint64_t),cudaMemcpyDeviceToHost);
    cudaMemcpy(ds_read_c,d_reads.core,numOfRead*sizeof(read_core_t),cudaMemcpyDeviceToHost);
    cudaMemcpy(ds_t,d_reads.strand,numOfRead*sizeof(uint8_t),cudaMemcpyDeviceToHost);
    FILE *p;
    p=fopen("/home/qianjiaqiang/dr.txt","w");
    for (uint32_t i=0;i<numOfRead;i++){
        fprintf(p,"%lu\t%lu\t%d\t%lu\t%lu\t%d\n",ds_read_s[i],ds_read_e[i],ds_t[i],ds_read_c[i].junctions[0].start_,ds_read_c[i].junctions[0].end_,int(d_indices[i]));
    }
    fclose(p);
    delete[] ds_read_s;
    delete[] ds_read_e;
    delete[] ds_read_c;
    delete[] ds_t;
    */

    // copy bins to device global memory
    d_Bins d_bins = gpu_chipMallocBin(h_bins, numOfBin);

    // copy ases to device global memory
    d_ASEs d_ases = gpu_chipMallocASE(h_ases, numOfASE);
    // auxiliary array
    Assist *d_assist_reads;
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_assist_reads, sizeof(Assist) * numOfBin));
    int32_t *d_read2bin_start;
    int32_t *d_read2bin_end;
    int32_t *d_nj_read2bin_start;
    int32_t *d_nj_read2bin_end;

    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_read2bin_start, sizeof(int32_t) * numOfBin));
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_read2bin_end, sizeof(int32_t) * numOfBin));
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_nj_read2bin_start, sizeof(int32_t) * numOfBin));
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_nj_read2bin_end, sizeof(int32_t) * numOfBin));

    // assign reads to bins
    std::cout << "starting assign reads..." << std::endl;
    gpu_assign_nj_read_kernel<<<nBlock, blockSize>>>(
        d_bins, numOfBin, d_nj_reads, numOfRead, d_assist_reads,
        d_nj_read2bin_start, d_nj_read2bin_end);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    gpu_assign_read_kernel<<<nBlock, blockSize>>>(
        d_bins, numOfBin, d_reads, numOfRead, d_assist_reads, d_read2bin_start,
        d_read2bin_end);

    CUDA_SAFE_CALL(cudaDeviceSynchronize());

    float *d_tempTPM, *d_tpmCounter;
    // d_tempTPM
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_tempTPM, numOfBin * sizeof(float)));
    CUDA_SAFE_CALL(cudaMemset(d_tempTPM, 0, numOfBin * sizeof(float)));
    // d_tpmCounter
    int32_t tpmSize = (nextPow2(nBlock) + 1) / 2;
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_tpmCounter, tpmSize * sizeof(float)));
    CUDA_SAFE_CALL(cudaMemset(d_tpmCounter, 0, tpmSize * sizeof(float)));
    // count temp
    float *tpmStore;
    tpmStore = new float[numOfBin];
    float *d_tpmStore;
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_tpmStore, numOfBin * sizeof(float)));

    std::cout << "starting count tpm..." << std::endl;
    gpu_count_tempTPM<<<nBlock, blockSize>>>(d_bins, numOfBin, d_tempTPM);
    reduceSinglePass(static_cast<int>(numOfBin), blockSize,
                     static_cast<int>(tpmSize), d_tempTPM, d_tpmCounter);
    gpu_count_TPM<<<nBlock, blockSize>>>(d_bins, numOfBin, d_tempTPM,
                                         d_tpmCounter, d_tpmStore);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    CUDA_SAFE_CALL(cudaMemcpy(tpmStore, d_tpmStore, numOfBin * sizeof(float),
                              cudaMemcpyDeviceToHost));

    // auxiliary array
    Assist *d_assist_ases;
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_assist_ases, sizeof(Assist) * numOfBin));
    int32_t *d_bin2ase;
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_bin2ase, sizeof(int32_t) * numOfASE));
    std::cout << "starting assign ases..." << std::endl;
    // assign ases to bins
    gpu_assign_ASE_kernel<<<nBlock, blockSize>>>(
        d_bins, numOfBin, d_ases, numOfASE, d_assist_ases, d_bin2ase);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());

    // auxiliary array
    Assist *d_assist_read_ases;
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_assist_read_ases, sizeof(Assist) * numOfASE));
    ASECounter *ACT;
    CUDA_SAFE_CALL(cudaMalloc((void **)&ACT, sizeof(ASECounter) * numOfASE));
    // compute number of thread block
    nBlock = (unsigned(numOfASE) + blockSize - 1) / blockSize;
    // assign reads to ases
    std::cout << "starting assign reads to ases..." << std::endl;
    // gpu_assign_read_ASE_kernel<<<nBlock, blockSize>>>(
    //   d_ases, numOfASE, d_reads, numOfRead, d_assist_read_ases, ACT);
    gpu_assign_nj_read_ASE_kernel<<<nBlock, blockSize>>>(
        d_ases, numOfASE, d_nj_reads, numOf_nj_Read, d_assist_read_ases, ACT,
        d_bin2ase, d_nj_read2bin_start, d_nj_read2bin_end);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    gpu_assign_read_ASE_kernel2<<<nBlock, blockSize>>>(
        d_ases, numOfASE, d_reads, numOfRead, d_assist_read_ases, ACT,
        d_bin2ase, d_read2bin_start, d_read2bin_end);

    CUDA_SAFE_CALL(cudaDeviceSynchronize());

    ASEPsi *d_ase_psi;
    size_t psiSize = sizeof(ASEPsi) * numOfASE;
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_ase_psi, psiSize));
    // count psi
    std::cout << "starting count psi..." << std::endl;
    gpu_count_PSI<<<nBlock, blockSize>>>(d_ases, numOfASE, d_ase_psi, ACT);

    CUDA_SAFE_CALL(cudaDeviceSynchronize());

    // psi
    ASEPsi *h_ase_psi = (ASEPsi *)malloc(psiSize);
    CUDA_SAFE_CALL(
        cudaMemcpy(h_ase_psi, d_ase_psi, psiSize, cudaMemcpyDeviceToHost));
    // tpm
    float tpmCounter = 0;
    CUDA_SAFE_CALL(cudaMemcpy(&tpmCounter, d_tpmCounter, sizeof(float),
                              cudaMemcpyDeviceToHost));
#define BETAINV
#ifdef BETAINV
    float *psi_ub;
    float *psi_lb;
    float *d_psi_ub;
    float *d_psi_lb;
    psi_ub = new float[numOfASE];
    psi_lb = new float[numOfASE];
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_psi_ub, numOfASE * sizeof(float)));
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_psi_lb, numOfASE * sizeof(float)));
    std::cout << "starting calculating beta.inv psi..." << std::endl;
    gpu_post_PSI<<<nBlock * 4, blockSize / 4>>>(d_ase_psi, ACT, d_psi_ub,
                                                d_psi_lb, numOfASE);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    CUDA_SAFE_CALL(cudaMemcpy(psi_ub, d_psi_ub, numOfASE * sizeof(float),
                              cudaMemcpyDeviceToHost));
    CUDA_SAFE_CALL(cudaMemcpy(psi_lb, d_psi_lb, numOfASE * sizeof(float),
                              cudaMemcpyDeviceToHost));
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    cudaFree(d_psi_ub);
    cudaFree(d_psi_lb);
#endif

#define DEBUG
#ifdef DEBUG
    // ase psi
    float countIn, countOut;
    UMAP::const_iterator gid, bin;
    NMAP::const_iterator bin_id;
    countIn = countOut = 0;
    std::cout.setf(std::ios::fixed);
    std::cout << "ase_event"
              << "\t"
              << "gene_name"
              << "\t"
              << "countIn"
              << "\t"
              << "countOut"
              << "\t"
              << "psi_lb"
              << "\t"
              << "psi_ub"
              << "\t"
              << "psi"
              << "\t"
              << "tpm" << std::endl;
    for (int i = 0; i < numOfBin; i++) {
        bin_id_map.insert({h_bins.core[i].name_h, i});
    }
    for (int i = 0; i < numOfASE; i++) {
        if (h_ase_psi[i].countIn) countIn++;
        if (h_ase_psi[i].countOut) countOut++;
        gid = g_gid_map.find(h_ase_psi[i].gid_h);
        bin = g_name_map.find(h_ase_psi[i].bin_h);
        bin_id = bin_id_map.find(h_ase_psi[i].bin_h);
        std::cout << gid->second << "\t"
                  << ((bin == g_name_map.end()) ? "null" : bin->second) << "\t"
                  << std::setprecision(3) << h_ase_psi[i].countIn << "\t"
                  << h_ase_psi[i].countOut
#ifdef BETAINV
                  << "\t" << psi_lb[i] << "\t" << psi_ub[i]
#endif

                  << "\t" << h_ase_psi[i].psi << "\t"
                  << ((bin == g_name_map.end()) ? -1 : tpmStore[bin_id->second])
                  << std::endl;
    }
    std::cout << std::setprecision(3) << countIn << "\t" << std::setprecision(3)
              << countOut << std::endl;
    // tpm
    std::cout << std::setprecision(3) << "tpm count: " << tpmCounter
              << std::endl;
#endif
#ifdef BETAINV
    delete[] psi_ub;
    delete[] psi_lb;
#endif
    /*
    int32_t *h_r2b_s;
    int32_t *h_r2b_e;
    h_r2b_s = new int32_t[numOfBin];
    h_r2b_e = new int32_t[numOfBin];
    cudaMemcpy(h_r2b_s,d_read2bin_start,sizeof(int32_t)*numOfBin,cudaMemcpyDeviceToHost);
    cudaMemcpy(h_r2b_e,d_read2bin_end,sizeof(int32_t)*numOfBin,cudaMemcpyDeviceToHost);
    FILE *d;
    d = fopen("/home/qianjiaqiang/r2b.txt","w");
    for (uint32_t i=0;i<numOfBin;i++){
        fprintf(d,"%d\t%d\n",h_r2b_s[i],h_r2b_e[i]);
        }
    fclose(d);
    delete[] h_r2b_s;
    delete[] h_r2b_e;
    */

    // free memory
    std::cout << "free memory..." << std::endl;
    cudaFree(d_ase_psi);
    cudaFree(d_tempTPM);
    cudaFree(d_tpmStore);
    cudaFree(d_tpmCounter);
    cudaFree(d_assist_reads);
    cudaFree(d_assist_ases);
    cudaFree(d_assist_read_ases);
    cudaFree(d_read2bin_start);
    cudaFree(d_read2bin_end);
    cudaFree(d_nj_read2bin_start);
    cudaFree(d_nj_read2bin_end);
    cudaFree(d_bin2ase);
    delete[] tpmStore;
}

void HandleBin_cub_tpm(h_Bins &h_bins, h_Reads &h_reads, h_nj_Reads &h_nj_reads,
                       h_ASEs &h_ases)
{
    int32_t numOfBin = int32_t(h_bins.start_.size());
    int32_t numOfRead = int32_t(h_reads.start_.size());
    int32_t numOfASE = int32_t(h_ases.start_.size());

    int32_t numOf_nj_Read = int32_t(h_nj_reads.start_.size());

    std::cout << "numOfBin: " << numOfBin << std::endl;
    std::cout << "numOfRead: " << numOfRead << std::endl;
    std::cout << "numOfASE: " << numOfASE << std::endl;

    std::cout << "numOfnjRead: " << numOf_nj_Read << std::endl;
    // compute number of thread block
    unsigned nBlock = (unsigned(numOfBin) + blockSize - 1) / blockSize;

    // copy reads to device global memory
    d_Reads d_reads = gpu_chipMallocRead(h_reads, numOfRead);
    d_nj_Reads d_nj_reads = gpu_chipMalloc_njRead(h_nj_reads, numOf_nj_Read);

    std::cout << "starting sorting reads..." << std::endl;
    uint32_t *ind;
    ind = new uint32_t[numOfRead];
    // ind = std::iota(ind,ind+numOfRead,0);
    for (uint32_t i = 0; i < numOfRead; i++) {
        ind[i] = i;
    }

    uint64_t *d_start_in;
    uint32_t *d_indices_in;
    uint32_t *d_indices;
    cudaMalloc((void **)&d_start_in, sizeof(uint64_t) * numOfRead);
    cudaMalloc((void **)&d_indices_in, sizeof(uint32_t) * numOfRead);
    cudaMalloc((void **)&d_indices, sizeof(uint32_t) * numOfRead);
    cudaMemcpy(d_start_in, d_reads.start_, sizeof(uint64_t) * numOfRead,
               cudaMemcpyDeviceToDevice);
    cudaMemcpy(d_indices_in, ind, sizeof(uint32_t) * numOfRead,
               cudaMemcpyHostToDevice);
    void *d_temp_storage = NULL;
    size_t temp_storage_bytes = 0;
    cub::DeviceRadixSort::SortPairs(d_temp_storage, temp_storage_bytes,
                                    d_start_in, d_reads.start_, d_indices_in,
                                    d_indices, numOfRead);
    cudaMalloc(&d_temp_storage, temp_storage_bytes);
    cub::DeviceRadixSort::SortPairs(d_temp_storage, temp_storage_bytes,
                                    d_start_in, d_reads.start_, d_indices_in,
                                    d_indices, numOfRead);

    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    cudaFree(d_temp_storage);
    cudaFree(d_indices_in);
    cudaFree(d_start_in);

    unsigned nReadBlock = (unsigned(numOfRead) + blockSize - 1) / blockSize;

    uint64_t *gatmp_read_e;
    cudaMalloc((void **)&gatmp_read_e, sizeof(uint64_t) * numOfRead);
    cudaMemcpy(gatmp_read_e, d_reads.end_, numOfRead * sizeof(uint64_t),
               cudaMemcpyDeviceToDevice);
    gather<uint64_t><<<nReadBlock, blockSize>>>(d_indices, gatmp_read_e,
                                                d_reads.end_, numOfRead);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    cudaFree(gatmp_read_e);

    uint8_t *gatmp_t;
    cudaMalloc((void **)&gatmp_t, sizeof(uint8_t) * numOfRead);
    cudaMemcpy(gatmp_t, d_reads.strand, numOfRead * sizeof(uint8_t),
               cudaMemcpyDeviceToDevice);
    gather<uint8_t><<<nReadBlock, blockSize>>>(d_indices, gatmp_t,
                                               d_reads.strand, numOfRead);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    cudaFree(gatmp_t);
    read_core_t *gatmp_c;
    cudaMalloc((void **)&gatmp_c, sizeof(read_core_t) * numOfRead);
    cudaMemcpy(gatmp_c, d_reads.core, numOfRead * sizeof(read_core_t),
               cudaMemcpyDeviceToDevice);
    gather<read_core_t><<<nReadBlock, blockSize>>>(d_indices, gatmp_c,
                                                   d_reads.core, numOfRead);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    cudaFree(gatmp_c);

    cudaFree(d_indices);
    delete[] ind;

    cudaMemcpy(h_reads.start_.data(), d_reads.start_,
               numOfRead * sizeof(uint64_t), cudaMemcpyDeviceToHost);
    cudaMemcpy(h_reads.end_.data(), d_reads.end_, numOfRead * sizeof(uint64_t),
               cudaMemcpyDeviceToHost);
    cudaMemcpy(h_reads.strand.data(), d_reads.strand,
               numOfRead * sizeof(uint8_t), cudaMemcpyDeviceToHost);
    cudaMemcpy(h_reads.core.data(), d_reads.core,
               numOfRead * sizeof(read_core_t), cudaMemcpyDeviceToHost);

    std::cout << "starting sorting nj_reads..." << std::endl;

    uint32_t *nj_indices;
    nj_indices = new uint32_t[numOf_nj_Read];
    for (uint32_t i = 0; i < numOf_nj_Read; i++) {
        nj_indices[i] = i;
    }
    uint32_t *d_nj_indices;
    uint32_t *d_nj_indices_in;
    uint64_t *d_nj_start_in;

    cudaMalloc((void **)&d_nj_indices, sizeof(uint32_t) * numOf_nj_Read);
    cudaMalloc((void **)&d_nj_indices_in, sizeof(uint32_t) * numOf_nj_Read);
    cudaMalloc((void **)&d_nj_start_in, sizeof(uint64_t) * numOf_nj_Read);
    cudaMemcpy(d_nj_start_in, d_nj_reads.start_,
               sizeof(uint64_t) * numOf_nj_Read, cudaMemcpyDeviceToDevice);
    cudaMemcpy(d_nj_indices_in, nj_indices, sizeof(uint32_t) * numOf_nj_Read,
               cudaMemcpyHostToDevice);
    d_temp_storage = NULL;
    temp_storage_bytes = 0;
    cub::DeviceRadixSort::SortPairs(
        d_temp_storage, temp_storage_bytes, d_nj_start_in, d_nj_reads.start_,
        d_nj_indices_in, d_nj_indices, numOf_nj_Read);
    cudaMalloc(&d_temp_storage, temp_storage_bytes);
    cub::DeviceRadixSort::SortPairs(
        d_temp_storage, temp_storage_bytes, d_nj_start_in, d_nj_reads.start_,
        d_nj_indices_in, d_nj_indices, numOf_nj_Read);

    uint64_t *gatmp_read_e_nj;
    uint8_t *gatmp_t_nj;
    cudaMalloc((void **)&gatmp_read_e_nj, sizeof(uint64_t) * numOf_nj_Read);
    cudaMalloc((void **)&gatmp_t_nj, sizeof(uint8_t) * numOf_nj_Read);
    cudaMemcpy(gatmp_read_e_nj, d_nj_reads.end_,
               numOf_nj_Read * sizeof(uint64_t), cudaMemcpyDeviceToDevice);
    cudaMemcpy(gatmp_t_nj, d_nj_reads.strand, numOf_nj_Read * sizeof(uint8_t),
               cudaMemcpyDeviceToDevice);

    gather<uint64_t><<<nReadBlock, blockSize>>>(d_nj_indices, gatmp_read_e_nj,
                                                d_nj_reads.end_, numOf_nj_Read);
    gather<uint8_t><<<nReadBlock, blockSize>>>(
        d_nj_indices, gatmp_t_nj, d_nj_reads.strand, numOf_nj_Read);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());

    cudaFree(gatmp_read_e_nj);
    cudaFree(gatmp_t_nj);
    cudaFree(d_nj_indices);
    cudaFree(d_nj_indices_in);
    cudaFree(d_nj_start_in);
    cudaFree(d_temp_storage);
    delete[] nj_indices;
    cudaMemcpy(h_nj_reads.start_.data(), d_nj_reads.start_,
               numOf_nj_Read * sizeof(uint64_t), cudaMemcpyDeviceToHost);
    cudaMemcpy(h_nj_reads.end_.data(), d_nj_reads.end_,
               numOf_nj_Read * sizeof(uint64_t), cudaMemcpyDeviceToHost);
    cudaMemcpy(h_nj_reads.strand.data(), d_nj_reads.strand,
               numOf_nj_Read * sizeof(uint8_t), cudaMemcpyDeviceToHost);

    std::cout << "end sorting nj_reads..." << std::endl;
    /*
    uint64_t *ds_read_s;
    uint64_t *ds_read_e;
    uint8_t *ds_t;
    read_core_t *ds_read_c;
    ds_read_s = new uint64_t[numOfRead];
    ds_read_e = new uint64_t[numOfRead];
    ds_read_c = new read_core_t[numOfRead];
    ds_t = new uint8_t[numOfRead];
    cudaMemcpy(ds_read_s,d_reads.start_,numOfRead*sizeof(uint64_t),cudaMemcpyDeviceToHost);
    cudaMemcpy(ds_read_e,d_reads.end_,numOfRead*sizeof(uint64_t),cudaMemcpyDeviceToHost);
    cudaMemcpy(ds_read_c,d_reads.core,numOfRead*sizeof(read_core_t),cudaMemcpyDeviceToHost);
    cudaMemcpy(ds_t,d_reads.strand,numOfRead*sizeof(uint8_t),cudaMemcpyDeviceToHost);
    FILE *p;
    p=fopen("/home/qianjiaqiang/dr.txt","w");
    for (uint32_t i=0;i<numOfRead;i++){
        fprintf(p,"%lu\t%lu\t%d\t%lu\t%lu\t%d\n",ds_read_s[i],ds_read_e[i],ds_t[i],ds_read_c[i].junctions[0].start_,ds_read_c[i].junctions[0].end_,int(d_indices[i]));
    }
    fclose(p);
    delete[] ds_read_s;
    delete[] ds_read_e;
    delete[] ds_read_c;
    delete[] ds_t;
    */

    // copy bins to device global memory
    d_Bins d_bins = gpu_chipMallocBin(h_bins, numOfBin);

    // copy ases to device global memory
    d_ASEs d_ases = gpu_chipMallocASE(h_ases, numOfASE);
    // auxiliary array
    Assist *d_assist_reads;
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_assist_reads, sizeof(Assist) * numOfBin));
    int32_t *d_read2bin_start;
    int32_t *d_read2bin_end;
    int32_t *d_nj_read2bin_start;
    int32_t *d_nj_read2bin_end;

    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_read2bin_start, sizeof(int32_t) * numOfBin));
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_read2bin_end, sizeof(int32_t) * numOfBin));
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_nj_read2bin_start, sizeof(int32_t) * numOfBin));
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_nj_read2bin_end, sizeof(int32_t) * numOfBin));

    // assign reads to bins
    std::cout << "starting assign reads..." << std::endl;
    gpu_assign_nj_read_kernel<<<nBlock, blockSize>>>(
        d_bins, numOfBin, d_nj_reads, numOfRead, d_assist_reads,
        d_nj_read2bin_start, d_nj_read2bin_end);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    gpu_assign_read_kernel<<<nBlock, blockSize>>>(
        d_bins, numOfBin, d_reads, numOfRead, d_assist_reads, d_read2bin_start,
        d_read2bin_end);

    CUDA_SAFE_CALL(cudaDeviceSynchronize());

    float *d_tempTPM, *d_tpmCounter;
    // d_tempTPM
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_tempTPM, numOfBin * sizeof(float)));
    CUDA_SAFE_CALL(cudaMemset(d_tempTPM, 0, numOfBin * sizeof(float)));
    // d_tpmCounter
    int32_t tpmSize = (nextPow2(nBlock) + 1) / 2;
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_tpmCounter, tpmSize * sizeof(float)));
    CUDA_SAFE_CALL(cudaMemset(d_tpmCounter, 0, tpmSize * sizeof(float)));
    // count temp
    float *tpmStore;
    tpmStore = new float[numOfBin];
    float *d_tpmStore;
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_tpmStore, numOfBin * sizeof(float)));
    int32_t *d_bin_length;
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_bin_length, numOfBin * sizeof(int32_t)));
    std::cout << "starting count tpm..." << std::endl;
    // cudaThreadSetLimit(cudaLimitMallocHeapSize, 1024*1024*1024);
    // modify_bin_length<<<nBlock*64,blockSize/64>>>(d_bins,d_read2bin_start,d_read2bin_end,numOfRead,d_nj_read2bin_start,d_nj_read2bin_end,numOf_nj_Read,d_reads,d_nj_reads,d_bin_length,numOfBin);
    // modify_bin_length<<<1,2>>>(d_bins,d_read2bin_start,d_read2bin_end,numOfRead,d_nj_read2bin_start,d_nj_read2bin_end,numOf_nj_Read,d_reads,d_nj_reads,d_bin_length,numOfBin);
    int32_t *bin_length;
    bin_length = new int32_t[numOfBin];

    int32_t *read2bin_start, *read2bin_end, *nj_read2bin_start,
        *nj_read2bin_end;
    read2bin_start = new int32_t[numOfBin];
    read2bin_end = new int32_t[numOfBin];
    nj_read2bin_start = new int32_t[numOfBin];
    nj_read2bin_end = new int32_t[numOfBin];

    CUDA_SAFE_CALL(cudaMemcpy(read2bin_start, d_read2bin_start,
                              sizeof(int32_t) * numOfBin,
                              cudaMemcpyDeviceToHost));
    CUDA_SAFE_CALL(cudaMemcpy(read2bin_end, d_read2bin_end,
                              sizeof(int32_t) * numOfBin,
                              cudaMemcpyDeviceToHost));
    CUDA_SAFE_CALL(cudaMemcpy(nj_read2bin_start, d_nj_read2bin_start,
                              sizeof(int32_t) * numOfBin,
                              cudaMemcpyDeviceToHost));
    CUDA_SAFE_CALL(cudaMemcpy(nj_read2bin_end, d_nj_read2bin_end,
                              sizeof(int32_t) * numOfBin,
                              cudaMemcpyDeviceToHost));
    int32_t *TPM_modify, *d_TPM_modify;
    TPM_modify = new int32_t[numOfBin];
    modify_bin_length_host(h_bins, read2bin_start, read2bin_end, numOfRead,
                           nj_read2bin_start, nj_read2bin_end, numOf_nj_Read,
                           h_reads, h_nj_reads, bin_length, numOfBin,
                           TPM_modify);
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_TPM_modify, sizeof(int32_t) * numOfBin));
    CUDA_SAFE_CALL(cudaMemcpy(d_TPM_modify, TPM_modify,
                              sizeof(int32_t) * numOfBin,
                              cudaMemcpyHostToDevice));
    CUDA_SAFE_CALL(cudaMemcpy(d_bin_length, bin_length,
                              sizeof(int32_t) * numOfBin,
                              cudaMemcpyHostToDevice));
    //gpu_count_tempTPM_modify<<<nBlock, blockSize>>>(d_bins, numOfBin,
    //                                                d_TPM_modify);

    delete[] bin_length;
    delete[] read2bin_start;
    delete[] read2bin_end;
    delete[] nj_read2bin_start;
    delete[] nj_read2bin_end;
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    delete[] TPM_modify;
    cudaFree(d_TPM_modify);
    gpu_count_tempTPM_new<<<nBlock, blockSize>>>(d_bins, numOfBin, d_tempTPM,
                                                 d_bin_length);
    // sum d_tempTPM
    float *tempTPM;
    float tpmsum = 0.0f;
    tempTPM = new float[numOfBin];
    cudaMemcpy(tempTPM, d_tempTPM, sizeof(float) * numOfBin,
               cudaMemcpyDeviceToHost);
    for (uint32_t i = 0; i < numOfBin; i++) {
        tpmsum += tempTPM[i];
    }
    delete[] tempTPM;
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    reduceSinglePass(static_cast<int>(numOfBin), blockSize,
                     static_cast<int>(tpmSize), d_tempTPM, d_tpmCounter);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    gpu_count_TPM<<<nBlock, blockSize>>>(d_bins, numOfBin, d_tempTPM,
                                         d_tpmCounter, d_tpmStore);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    CUDA_SAFE_CALL(cudaMemcpy(tpmStore, d_tpmStore, numOfBin * sizeof(float),
                              cudaMemcpyDeviceToHost));

    // auxiliary array
    Assist *d_assist_ases;
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_assist_ases, sizeof(Assist) * numOfBin));
    int32_t *d_bin2ase;
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_bin2ase, sizeof(int32_t) * numOfASE));
    std::cout << "starting assign ases..." << std::endl;
    // assign ases to bins
    gpu_assign_ASE_kernel<<<nBlock, blockSize>>>(
        d_bins, numOfBin, d_ases, numOfASE, d_assist_ases, d_bin2ase);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());

    // auxiliary array
    Assist *d_assist_read_ases;
    CUDA_SAFE_CALL(
        cudaMalloc((void **)&d_assist_read_ases, sizeof(Assist) * numOfASE));
    ASECounter *ACT;
    CUDA_SAFE_CALL(cudaMalloc((void **)&ACT, sizeof(ASECounter) * numOfASE));
    // compute number of thread block
    nBlock = (unsigned(numOfASE) + blockSize - 1) / blockSize;
    // assign reads to ases
    std::cout << "starting assign reads to ases..." << std::endl;
    // gpu_assign_read_ASE_kernel<<<nBlock, blockSize>>>(
    //   d_ases, numOfASE, d_reads, numOfRead, d_assist_read_ases, ACT);
    gpu_assign_nj_read_ASE_kernel<<<nBlock, blockSize>>>(
        d_ases, numOfASE, d_nj_reads, numOf_nj_Read, d_assist_read_ases, ACT,
        d_bin2ase, d_nj_read2bin_start, d_nj_read2bin_end);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    gpu_assign_read_ASE_kernel2<<<nBlock, blockSize>>>(
        d_ases, numOfASE, d_reads, numOfRead, d_assist_read_ases, ACT,
        d_bin2ase, d_read2bin_start, d_read2bin_end);

    CUDA_SAFE_CALL(cudaDeviceSynchronize());

    ASEPsi *d_ase_psi;
    size_t psiSize = sizeof(ASEPsi) * numOfASE;
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_ase_psi, psiSize));
    // count psi
    std::cout << "starting count psi..." << std::endl;
    gpu_count_PSI<<<nBlock, blockSize>>>(d_ases, numOfASE, d_ase_psi, ACT);

    CUDA_SAFE_CALL(cudaDeviceSynchronize());

    // psi
    ASEPsi *h_ase_psi = (ASEPsi *)malloc(psiSize);
    CUDA_SAFE_CALL(
        cudaMemcpy(h_ase_psi, d_ase_psi, psiSize, cudaMemcpyDeviceToHost));
    // tpm
    float tpmCounter = 0;
    CUDA_SAFE_CALL(cudaMemcpy(&tpmCounter, d_tpmCounter, sizeof(float),
                              cudaMemcpyDeviceToHost));
#define BETAINV
#ifdef BETAINV
    float *psi_ub;
    float *psi_lb;
    float *d_psi_ub;
    float *d_psi_lb;
    psi_ub = new float[numOfASE];
    psi_lb = new float[numOfASE];
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_psi_ub, numOfASE * sizeof(float)));
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_psi_lb, numOfASE * sizeof(float)));
    std::cout << "starting calculating beta.inv psi..." << std::endl;
    gpu_post_PSI<<<nBlock * 4, blockSize / 4>>>(d_ase_psi, ACT, d_psi_ub,
                                                d_psi_lb, numOfASE);
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    CUDA_SAFE_CALL(cudaMemcpy(psi_ub, d_psi_ub, numOfASE * sizeof(float),
                              cudaMemcpyDeviceToHost));
    CUDA_SAFE_CALL(cudaMemcpy(psi_lb, d_psi_lb, numOfASE * sizeof(float),
                              cudaMemcpyDeviceToHost));
    CUDA_SAFE_CALL(cudaDeviceSynchronize());
    cudaFree(d_psi_ub);
    cudaFree(d_psi_lb);
#endif

#define DEBUG
#ifdef DEBUG
    // ase psi
    float countIn, countOut;
    UMAP::const_iterator gid, bin;
    NMAP::const_iterator bin_id;
    countIn = countOut = 0;
    std::cout.setf(std::ios::fixed);
    std::cout << "ase_event"
              << "\t"
              << "gene_name"
              << "\t"
              << "countIn"
              << "\t"
              << "countOut"
              << "\t"
              << "psi_lb"
              << "\t"
              << "psi_ub"
              << "\t"
              << "psi"
              << "\t"
              << "tpm" << std::endl;
    for (int i = 0; i < numOfBin; i++) {
        bin_id_map.insert({h_bins.core[i].name_h, i});
    }
    for (int i = 0; i < numOfASE; i++) {
        if (h_ase_psi[i].countIn) countIn++;
        if (h_ase_psi[i].countOut) countOut++;
        gid = g_gid_map.find(h_ase_psi[i].gid_h);
        bin = g_name_map.find(h_ase_psi[i].bin_h);
        bin_id = bin_id_map.find(h_ase_psi[i].bin_h);
        std::cout << gid->second << "\t"
                  << ((bin == g_name_map.end()) ? "null" : bin->second) << "\t"
                  << std::setprecision(3) << h_ase_psi[i].countIn << "\t"
                  << h_ase_psi[i].countOut
#ifdef BETAINV
                  << "\t" << psi_lb[i] << "\t" << psi_ub[i]
#endif

                  << "\t" << h_ase_psi[i].psi << "\t"
                  << ((bin == g_name_map.end()) ? -1 : tpmStore[bin_id->second])
                  << std::endl;
    }
    std::cout << std::setprecision(3) << countIn << "\t" << std::setprecision(3)
              << countOut << std::endl;
    // tpm
    std::cout << std::setprecision(3) << "tpm count: " << tpmCounter
              << std::endl;
#endif
#ifdef BETAINV
    delete[] psi_ub;
    delete[] psi_lb;
#endif
    /*
    int32_t *h_r2b_s;
    int32_t *h_r2b_e;
    h_r2b_s = new int32_t[numOfBin];
    h_r2b_e = new int32_t[numOfBin];
    cudaMemcpy(h_r2b_s,d_read2bin_start,sizeof(int32_t)*numOfBin,cudaMemcpyDeviceToHost);
    cudaMemcpy(h_r2b_e,d_read2bin_end,sizeof(int32_t)*numOfBin,cudaMemcpyDeviceToHost);
    FILE *d;
    d = fopen("/home/qianjiaqiang/r2b.txt","w");
    for (uint32_t i=0;i<numOfBin;i++){
        fprintf(d,"%d\t%d\n",h_r2b_s[i],h_r2b_e[i]);
        }
    fclose(d);
    delete[] h_r2b_s;
    delete[] h_r2b_e;
    */

    // free memory
    std::cout << "free memory..." << std::endl;
    cudaFree(d_ase_psi);
    cudaFree(d_tempTPM);
    cudaFree(d_tpmStore);
    cudaFree(d_tpmCounter);
    cudaFree(d_assist_reads);
    cudaFree(d_assist_ases);
    cudaFree(d_assist_read_ases);
    cudaFree(d_read2bin_start);
    cudaFree(d_read2bin_end);
    cudaFree(d_nj_read2bin_start);
    cudaFree(d_nj_read2bin_end);
    cudaFree(d_bin2ase);
    delete[] tpmStore;
}

int main(int argc, char **argv)
{
    if (argc != 5) {
        std::cerr << "usage: " << argv[0]
                  << " [GFF file path] [BAM file path] [GFF file path]"
                  << std::endl;
        return 1;
    }

    struct timeval start_time, t_time, t2_time;
    gettimeofday(&start_time, 0);

    // load bins and ases.
    h_Bins h_bins;
    h_ASEs h_ases;

    struct stat buffer;
    if (stat(serFilename, &buffer) == 0) {
        std::cout << "loading bins and ases from serialization..." << std::endl;
        LoadDataFromSerialization(h_bins, h_ases);
    } else {
        std::cout << "loading bins..." << std::endl;
        LoadBinFromGff(h_bins, argv[1]);

        std::cout << "loading ases..." << std::endl;
        LoadAseFromGFF(h_ases, argv[3]);

        std::cout << "saving bins and ases to serialization..." << std::endl;
        SaveDataToSerialization(h_bins, h_ases);
    }

    // load reads
    std::cout << "loading reads..." << std::endl;
    h_Reads h_reads;
    h_nj_Reads h_nj_reads;
    LoadReadFromBam(h_reads, h_nj_reads, argv[2]);

    gettimeofday(&t_time, 0);
    std::cout << "load spent time: "
              << (float)(t_time.tv_sec - start_time.tv_sec) << "s" << std::endl;

    std::cout << "start kernel program..." << std::endl;
    std::string option_cub = "cub";
    std::string option_thrust = "thrust";
    if (option_cub.compare(argv[4]) == 0) {
        HandleBin_cub_tpm(h_bins, h_reads, h_nj_reads, h_ases);
    }
    if (option_thrust.compare(argv[4]) == 0) {
        HandleBin(h_bins, h_reads, h_nj_reads, h_ases);
    }
    gettimeofday(&t2_time, 0);
    std::cout << "computing spent time: "
              << (float)(t2_time.tv_sec - t_time.tv_sec) << "s" << std::endl;
}
